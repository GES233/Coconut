# Coconut 设计草案：Headless Editor

> 2026-07-29 调研讨论存档。来源：对 Qy 下 tamale / oi / equinox / zongzi /
> zongzi_feasibility 五个项目的调研结论与架构决策。状态：部分实现
> （2026-08-03 更新：Track-ification（§11.1–11.3、11.8）、拍号入 Workspace、
> golden 场景最小集已落地，逐项进度见第 10 节标注）。

## 1. 定位与选型

coconut 是一个 **Headless Editor**（无 UI 的 SVS 编辑器内核），不是重写这些库：

- **介入机制 = tamale**（`Qy/tamale`）：Space / Op / Anchor / Transport / Patch，
  零依赖纯函数内核，三方合并模型，测试 + JSON 一致性向量齐全。
- **调度引擎 = orchid/oi**（`Qy/Orchid` + `Qy/oi`）：已固化，维护者即本人；
  未来变化只会以新 Executor/Hook 形式出现。直接作为稳定平台依赖，不重写。
- **集成参照 = equinox**（`Qy/equinox`）：domain + kernel 两层（去掉 ui_shell）
  即 headless editor 的骨架；Runner 的"两段式 check + 装配 + Blackboard 增量
  缓存"架构照搬，其中 zongzi Declaration 部分换成 tamale。
- zongzi / zongzi_feasibility 不再直接使用；后者的 Scenario 模式已移植为
  coconut 的验收测试（最小集，Measurer 报告台不搬，见 §10 第 2 条）。

## 2. 总体架构

```
接口层（Elixir API / JSON-RPC stdio / CLI / MCP，可扩展）
  → command 翻译 + dispatch（按 workspace_id 路由）
  → Workspace（聚合根，单写者，命令全序点；当前纯模块，GenServer 壳后加，§10.6）
      tracks: %{track_id => Track.t()}    # 音符轨
      tempo: Track.t()                    # tempo 轨独立字段，有且仅有一条（已定 2026-08-03）
      tpqn / time_sigs                    # 工程级：tick 分辨率 + 拍号事件
      Track = Space.t() + 侧表（版本化 span 表 / elements_by_id）
              + patches / dead_patches（坟场）
    命令处理流程：
      1. 校验 + base version 检查（过期拒绝，幂等）
      2. lowering：编辑手势 → op 批次（拖音符 = Move+Retime 同批）
      3. apply_batch 到各 Space，版本 +1，侧表/快照同步写回
      4. transport：存活 patch 的 anchor 沿新 log 运输（写时回写；死 patch 入坟场）
      5. 存活集合 → Resolve → Engine check/render（异步 job，事件回推）
```

术语对齐：**Workspace（工程）→ Track（轨 = 一个 Space + 侧表）→ Element
（音符 / tempo 事件）**。不使用 "Timeline" 一词（避免与 zongzi 旧机制串味）。

## 3. 桥接层（`Coconut.Resolve`）

> 2026-08-01 补记：实现定名 `Coconut.Resolve`（`lib/coconut/resolve.ex`），
> 原拟名 ACF 废弃；Engine behaviour 见 `lib/coconut/engine.ex`，两段式
> check/render 经 `Coconut.Engine.Request` 传递。
>
> 2026-08-02 补记：channel 抽象为 `Coconut.Channel` behaviour，不写死
> （注册表即 `run_check/3` 的 channels map，值可为 behaviour 模块或
> ad-hoc spec map；首个内置 `Coconut.Engines.Channels.Lyric`）。不挂音符的全局
> 参数走 `Request.globals`：过 check（`Engine.info` 的 `:globals` 声明做
> 白名单+范围/枚举校验）、不过 resolve（无 anchor/digest/transport），
> render 透传。两段式的交接：`Engine.check/2` 的 checked 由 `render/3`
> 消费而不重算——DiffSinger 的 dur/pitch 前向即经此复用。两层 check
> （Resolve 与 Engine）统一 verdict 语义：`{:ok, %{passed: ...}}` = 检查
> 执行完毕（false 即否决，entries 为全量明细），`{:error, _}` 只留给
> 检查自身无法执行（worker 崩溃、配置缺失、输入无法装配）。Encoder 契约
> `Coconut.Encoder`（note→request token，形状对契约不透明、由引擎定义）：
> phrase 粒度、逐轨调用、现算，具体机制由引擎开发者实现（首个实现
> Literal）；v1 手动配置，声库自动推导留待声库声明层。
>
> 2026-08-02 补记 II：元素数据流定为 Map → Note → ……——`Operate`
> lowering 把音符 attrs 铸成 `Coconut.Score.Note`（pitch → `Key.TwelveET`，
> 其余进 metadata），`elements_by_id` 直接存 struct；tempo 事件等非音符
> 元素仍存裸 map。digest 场景走 `Note.to_canonical/1`（key 经
> `Map.from_struct` 归约为 `%{midi: n}`，Tamale.Digest 拒 struct）。

tamale 与 oi 范式不同，桥接层显式隔离，职责只三条：

1. tamale transport/resolve 结果 → 折叠为 oi 的 `%{PortRef => %{input: value}}`
   data 干预（存活干预转 `:override`，按 producer 端口 keying）；
2. conflict（含 clip / ambiguous）全量聚合为一票否决（verdict
   `%{passed: false, entries}`；equinox Runner 语义照搬）；
3. 反向：用户编辑手势 → tamale Op 脚本。

参照：equinox `Runner.resolve_units` / `fold_resolved`。

## 4. 时间基准（硬约定）

- **tick = 结构层权威坐标**：音符、介入锚都挂 tick（Metric 或 Ordinal）。
- **帧/采样点 = 引擎层坐标**：digest 投影与渲染窗口使用，整数帧号。
- **秒只允许以整数微秒出现在导出/展示边界**。float 在所有内核边界被拒绝
  （tamale Coord 学说），归一化在适配层完成，舍入只发生在最终消费点。
- **tempo 只支持阶梯（step），不支持线性 ramp**——Warp 段是有理数端点的
  线性段，ramp 的二次曲线无法精确表达，会破坏 digest 零容忍比对。
  渐速靠加密 tempo 点逼近，采样端拟合。
- tick↔帧换算收敛到唯一一处（warp_provider / Resolve 采样处），
  zongzi_feasibility 的教训：跨语言舍入一致性是隐形地雷。

## 5. warp_provider 设计

契约：`(coord, log_entry) -> Warp.t()`，每版本批次每坐标系一个 warp，
无段时间按 identity。原料来源：

| op | warp 段 | 原料 |
|---|---|---|
| Retime(id, old, new) | `{old, new}` 段 | op 自足 |
| Move + Retime 同批 | 同上 | op 自足 |
| Delete(id) | 洞（无像区间） | 需版本化 span 表 |
| Insert | 插入点后平移段（ripple；v1 为 identity） | 需版本化 span 表 |
| Split / Merge / 纯内容编辑 | identity | — |

设计主张：

1. **v1 只支持 `:tick` 坐标**；帧空间 Metric 锚在挂载时拒绝。tick warp 与
   tempo 无关（tempo 变化 tick 不动），provider 是纯函数：
   `ops + span 快照 → Warp`。
2. 维护**版本化 span 表** `%{version => %{id => span}}`（不可变 map 结构共享，
   每版一份近零成本；随 Space.truncate 同步裁剪）。不需要 Tick↔Sample 表
   ——TempoMap 本身就是那张换算表，现算即可。
3. **ripple 策略藏在 provider 里**：v1 走非 ripple（钢琴卷语义，拉伸音符不
   推动后续）。要 ripple 时在段表后追加平移段即可，内核与 op 不变。
4. 帧空间 warp（v2）：`W_frame = T_new ∘ W_tick ∘ T_old⁻¹`，用
   `Warp.compose/invert` 组合。验收用 tamale 一致性向量 metric 族
   （G-INT-03/05 场景）。

## 6. Tempo Track = 一条独立 Space

tempo 变化作用于工程所有轨道 → tempo 是工程级数据：

- tempo 事件作为元素住自己的 Space（id + tick span + 侧表存 bpm）；
- bpm 以 milli-bpm 整数存储（有理数）；请求侧收普通 bpm 数值，由
  `Tempo.cast_bpm/1` 在 lower 时归一化（float 只在此一处舍入）；
- tempo 编辑自动落 op log（Insert/Delete/Retime），为帧 warp 提供原料；
- 平铺约定：已定（2026-08-03），宽松——洞由阶梯语义自然继承前一元素
  bpm（TempoMap 段持续至下一事件），首元素受保护不可删除（已落
  `Track.Tempo.validate_gesture/3`）；
- `:tick` provider 对 tempo log 永远返回 identity；tempo Space 自身几乎
  不会被挂锚，其角色是"序列化容器 + log 发生器"；
- tempo 轨的存放：已定（2026-08-03）——Workspace 独立 `tempo` 字段，
  有且仅有一条（结构性保证）；绑定按能力不按模块身份：任何导出
  `tempo_events/1` 的 track module 都可充当 tempo 轨（投影知识在模块上，
  `Workspace.validate/1` 把关能力与 id 冲突）；`fetch_track/2`/
  `apply_batch/5` 等按 track id 透明路由到该字段；空 tempo 轨（无事件）
  时 `Workspace.tempo_map/1` 报 `:no_tempo_track`，引擎走自有回退；
- 拍号（TimeSig）：已定（2026-08-03）——**不作 track**，落 `Workspace`
  的 `time_sigs` 字段（`[{bar, sig}]` 事件列表，支持曲子中途变拍如
  4/4 → 3/4；bar 是权威坐标，首事件须在 bar 1 且小节序号严格递增，
  `Workspace.validate/1` 把关）。它是 tick 之上的显示/网格叠层（小节
  标尺、吸附），不移动 tick、无锚、无 transport，进 Space 是纯开销；
  `TimeSigMap` 读时编译（`Workspace.time_sig_map/1`，按 `ws.tpqn`）。
  散拍子 `:san` 暂不考虑。

## 7. Op 覆盖评估

六 op（Insert/Delete/Split/Merge/Move/Retime）覆盖"顺序、身份、时间"三个
正交轴，音符序列 + 曲线参数的编辑需求为最小闭集：

- 纯内容编辑（歌词/音素/曲线控制点）**不落 op**，只写侧表，走 Patch/digest
  语义轴；
- 撤销/重做 = 追加逆批次（append-only，不写回滚）——inverse batch 生成
  逻辑需自写；
- 跨轨拖动 = 源 Space Delete + 目标 Space Insert，锚判死由策略层重挂
  （"Relocation is policy, not transport"；死 patch 在各轨的
  `track.dead_patches` 等策略层经 `Workspace.take_dead_patches/1` 收取）；
- 跨 Space 原子性由 Workspace 串行化 + 校验前置保证；
- 非单调碰撞（扩张/右移压过邻域）的 Metric 锚按旧域序水位线裁决：先到
  先得像，后续 identity 截断、冲突段成洞，受影响锚死于 transport
  （warp_provider 场景测试已钉死）；
- 同轨复音（重叠音符）不支持；协作/离线分支不支持（单写者线性 log）。

## 8. 已知缺口（需在 coconut 侧补齐）

tamale scaffold 阶段缺三件辅助 + 适配层函数：

1. warp-provider 参考实现 → 已落地（`Coconut.WarpProvider`，本设计第 5 节的
   v1 非 ripple 版）；
2. `diff(old, new)` 回退适配器（编辑来源是状态而非 op 时需要，如文件导入）
   ——启发式集中在这一个函数；
3. chunked digest helper；
4. undo 的 inverse batch 生成；
5. 跨 Space 重挂策略（跨轨拖动）。

## 9. 前置条件（动手前需定）

1. 引擎面：驱动的引擎是谁（决定 Engine behaviour 与 digest 投影实现）
   ——已定（2026-08-02）：首发 DiffSinger（OpenUTAU 格式声库），经
   `Coconut.Engines.DiffSinger` + `lib/coconut/engines/diffsinger/worker.py`（NDJSON stdio）
   接入；UTAU classic 备选，歌词→请求 token 的 Encoder 层单开；
2. 坐标基准：已定（tick 权威 + 帧 + 微秒，见第 4 节）；
3. 首发 channel 清单——已定（2026-08-02）：抽象为 `Coconut.Channel`
   behaviour，不写死；首发音素 / 音素时长 / 音高三路已落地
   （`Engines.Channels.Lyric` / `Duration` / `Pitch`，对齐 DiffSinger 的
   tokens/durations/f0 三路模型输入），每 channel 一个 adapter：warp_payload
   + digest 投影，是工作量乘数；
4. API 边界形状：首发建议 Elixir API + JSON-RPC/stdio + CLI 三件套，
   MCP 可后加；渲染为长任务（check 同步一票否决，render 异步 job + 事件）；
5. 持久化：工程文件落盘与否（equinox 的 Pickle codec 可参考）。

## 10. 实施顺序建议

1. Workspace 纯函数内核：lowering + transport（命令流第 2、4 步）——已完成
   （`Coconut.Workspace` / `Coconut.Operate`，写时 transport + 死 patch 坟场）；
2. golden 场景验证台（移植 zongzi_feasibility 的 Scenario 模式）——
   已落地最小集，暂停扩家族（已定 2026-08-03）：只搬 Scenario 契约 +
   对抗轮驱动（`test/support/scenario.ex`，runner 直接走
   `Operate → apply_batch → Resolve.run_check`），Measurer 的 PNG/HTML
   报告不搬（绑真引擎投影出图，coconut 的投影是 channel digest 切片，
   无图可画）；G-INT-01/02 已落地（`test/support/scenarios/`，挂
   `test/coconut/scenarios_test.exs`，不挂 :integration）。
   G-INT-01 按 coconut 语义重写：zongzi 的 split 裂子干预不搬，
   patch 存活于左半、右半天然无 patch 钉为验收点。
   暂停理由：验证台初衷是"没有编辑器时的假编辑器"，如今编辑回路
   已成型、机制面由常规 ExUnit 覆盖；难场景（G-PRE 族、相对曲线）
   需引擎投影级 snapshot，等真实投影/曲线落地后直接对 coconut
   语义写新验收，不再回翻 zongzi；
3. tamale 接入 + warp_provider（:tick 非 ripple 版）——已完成
   （`Coconut.WarpProvider`）；
4. Tempo Track Space + TempoMap fold——已完成（`Coconut.Score.Tempo` /
   `TempoMap`，bpm 在 lower 时归一化为 milli-bpm）；
5. 桥接 + Engine 两段式（check/render）——部分完成：`Coconut.Resolve` +
   `Coconut.Engine` behaviour + `Coconut.Engines.Mock` 已落地；channel 注册表
   （`Coconut.Channel` behaviour + 内置 `Engines.Channels.Lyric`）与全局参数闸门
   （`Request.globals` + `info` 声明校验）已落地；首个真实引擎
   `Coconut.Engines.DiffSinger` 已落地（Python worker 经 NDJSON stdio，
   globals 已接入）；orchid/oi 真实接入
   未开始（`Coconut.Engines.OrchidAdapter` 仅占位）；pitch override 已全链路
   打通（`Engines.Channels.Pitch` → `{:port, note_id, :pitch}` → adapter 秒域曲线 →
   worker 帧域 pitch_in/retake）；Encoder 契约 + Literal + worker dsdict
   编码器已落地（汉字歌词 → pypinyin → 声库 dsdict 查表，字典按语言
   懒加载 + CSafeLoader）；dur override 已接入（`Engines.Channels.Duration` → 钉音素帧数，未钉
   按比例吸收；顺带修债：ph_dur 逐 word 归一到记谱帧数，渲染长度不再
   偏离乐谱）；
6. GenServer 壳 + 接口层（JSON-RPC/stdio 优先）——未开始（Workspace 目前
   仍是纯模块）；
7. 帧空间锚 + tempo 对组合（v2）——未开始。

工作量估计：约 3–4 周（单人），风险集中在 Caller 义务（warp 构造、
digest 投影、float 归一化）与隐式约定密集，而非代码量。

## 11. 已知架构问题与演进方向（2026-08-02 评审）

引擎接口已知会大改（渲染不落盘、音频走内存），本节不含此项。以下为评审
确认的存量问题，按实质程度排序；未标注「已定」的方向均未拍板，改动前
需先在这里更新结论。

### 11.1 Request 直塞 Workspace 内部结构；Snapshot/Artifact 空壳（已落地 2026-08-03）

**已落地**：`Snapshot.from_workspace/1` 拍扁各轨 view（`Track.view/1`）+ 编好
`TempoMap` + 钉 `edit_version`；`Request` 携带 Snapshot（`for_workspace/2` 构造），
引擎不再见 Workspace。`Artifact{engine, edit_version, payload, globals,
overrides}` 为渲染产物正式形状，DiffSinger/Mock 已采用。三份"拍扁乐谱"
（DiffSinger.collect_notes / Mock.collect_latest_spans / Workspace.latest_spans
外泄）收敛为 `Track.view/1`。

**现象**（原问题，存档）：`Coconut.Engine.Request` 把整个 `Workspace` 交给引擎，引擎各自
解析 `side` 的内部结构——`DiffSinger.collect_notes`、`MockEngine.
collect_latest_spans`、`Workspace.latest_spans` 三份"拍扁乐谱"的逻辑并存。
`lib/coconut/engine/snapshot.ex` / `artifact.ex` 至今是占位空壳。

**为什么痛**：引擎不该知道 `spans_by_version`、`elements_by_id` 长什么样；
side 结构一变所有引擎跟着碎。Map → Note 管线落地后，下游需要的是一层
正式的"乐谱视图"。

**方向**：`Snapshot` = 拍扁的乐谱视图（各轨有序 `[{Note, span}]`、编好的
`TempoMap`、版本钉），`Request` 携带 Snapshot 而非 Workspace；`Artifact`
同
期定义为渲染产物的正式形状（为不落盘渲染铺路）。引擎只读 Snapshot。

### 11.2 时间双真相：Note tick vs spans 表（已落地 2026-08-03，方案 a）

**现象**：`Note.start_tick/duration_tick` 是插入时快照，`spans_by_version`
才是时间权威；transport 只更新后者，split 继承时手工同步前者。

**为什么痛**：两处都"像真的"，读错一处就是静默错位。

**已定（2026-08-03）：方案 a**——Note 不存 tick，只做内容载体（key/lyric/
metadata），时间一律走 spans 表。核实依据：lib 内无任何引擎读
`Note.start_tick`（DiffSinger 组包用 spans 表），tick 字段事实上已是
write-only；`Note.split/merge` 的几何校验改为由调用方注入 span。

**已落地**：Note 去 tick 完成；split/merge 改签名注入 span；Operate 的
split 继承变为纯 id 置换（`Track.Vocal.split_inherit/2`）。

**已退役（2026-08-04）**：`Note.split/5`、`Note.merge/6` 删除——workspace
的 split/merge lowering 走 span 几何 + `split_inherit`，从不经过 Note；
这两个函数在 lib/test/examples 均无任何调用方。内容（lyric 等）合并
策略留给调用方，走 `Coconut.Operations.EditNote`。

### 11.3 side 杂物抽屉（已落地 2026-08-03）

**已落地**：Side struct 整个删除——spans/elements/patches/dead_patches
随 `Coconut.Track` 下沉（tempos_by_version 占位随之消失，v2 变 tempo 需要时
再议）；`Track.truncate/2` + `Workspace.truncate/3` 已接入同步裁剪
（span 快照保留 cut 处最新一份作 baseline，warp 的 `spans_at(v-1)` 需要它）。

**现象**（原问题，存档）：`Side` 一个 struct 装 spans_by_version / elements_by_id / patches
/ dead_patches / tempos_by_version（占位从未写入）；`spans_by_version`
无界增长，`Space.truncate` 的"同步裁剪"未实现。

**方向**：启用 `tempos_by_version`（变 tempo 时的 transport 锚定需要它）
或删字段；接入 truncate 裁剪；side 拆分命名（乐谱侧表 / 干预侧表）。

### 11.4 port_ref 语义（已定：废元组，改 DTO）

**现象**：`{:port, node, port}` 的 node 位一会是角色名（`:synth`）一会是
音符 id；fold 同 port 后来者**静默**覆盖先来者；端口认领靠各 adapter
模式匹配自觉，无注册机制。

**已定方向**：port 引用改为显式 DTO（Map 或 Struct，不用位置元组），
字段命名语义（如 `%{scope, kind, id}`）；fold 的覆盖语义显式化——同
port 多次写入是合法覆盖还是冲突要在 Resolve 有说法；端口认领在多引擎
并存前要有注册/声明处（配合 capability 声明）。

### 11.5 check → render 无版本钉（部分落地）

**现象**：`Request` 是值快照，checked 之后 workspace 变了无人发现，全靠
调用方顺序自觉。

**方向**：`edit_version` 钉进 `Request`/`checked`，`run_render` 校验一致
（随 GenServer 壳一起做）。

**进展（2026-08-03）**：钉已随 Snapshot 落地（`Snapshot.edit_version`，
`Request.for_workspace/2` 构造即钉；`Artifact.edit_version` 记录渲染来源版本）。
强制校验仍随 GenServer 壳。

### 11.6 PortClient 无监督 + key 切换队列污染

**现象**：全局单例 GenServer 不在 supervision tree 下；worker key 变化时
旧 key 的排队请求会落到新 worker（v1 注释妥协）。

**方向**：挂监督树；key 切换时 fail 掉旧队列而非误投（多声部/多声库时
重做）。

### 11.7 毛边（记入 backlog，随用随修）

- 错误词汇两套：`missing_x` / `bad_x` / `unknown_x` 混用，接口层对外前
  统一。
- ~~Operate request 为 6~7 元 tagged tuple，位置参数多；成为 wire format
  前再评。~~ 已解决：request 改为 `Coconut.Operations.*` struct
  （`Operate` 仅做 dispatch）。
- `Note.to_canonical` 的 key 形状（`%{midi: n}`）是隐性契约：换 tuning
  或改形状 = 全部已挂 patch 的 base_digest 失效。改 canonical 形状视为
  breaking change。
- `Workspace.tempo_map/1` 每次现编 TempoMap；大工程下考虑缓存
  （与 tempos_by_version 一并想）。

### 11.8 Track 抽象（已定 2026-08-03，与 11.1–11.3 同期施工；Vocal/Tempo 已落地）

**已定方案**：引入 `Coconut.Track`（struct + behaviour），与 11.1–11.3
合并为一次重构（"Track-ification"），避免 side/spans 归属代码二次搬迁。
Operate 臃肿的根源（`:tempo` 特判 4 个 clause）正是 Track 该吸收的东西。

**已落地（2026-08-03）**：Track struct + behaviour + `Track.Vocal` /
`Track.Tempo`；Side 删除；Operate 只剩通用几何/序列校验，元素政策全部
走 track module 回调；`validate_gesture` 的 `:insert` 钩子是 v2 人声轨
不重叠约束的挂载点。`Track.Audio`（帧域）与 `Track.Synth` 未实现。

- `%Track{id, module, space, spans_by_version, elements_by_id, patches,
  dead_patches}`——Side 整个删除，Workspace = `id/edit_version/tracks`
  + 独立 `tempo` 轨字段 + 工程级 `tpqn/time_sigs`（§6）。
- behaviour 回调（克制，不含 Audio 占位共 6 个）：`coord_domain/0`、
  `cast_element/3`、`edit_element/2`、`validate_gesture/3`、
  `split_inherit/2`、`view/1`。`edit_element/2`（2026-08-03 补）：
  内容编辑的合并+重铸，`edit_note` lowering 经它一步写回（原 `:touch`
  stub 退役，调用方不再各自扮演 cast 义务）。
- 首发模块：`Track.Vocal`（Note 元素，tick 域）、`Track.Tempo`（bpm 裸 map，
  tick 域，首元素删除保护落 validate_gesture）。`Track.Audio` 紧随其后，
  `Track.Synth` 留位（参数面比 Vocal 简单，不预留实现）。
- **Audio = 帧域轨道（已定）**：clip 的位置与内容都在帧/采样域——
  `source_offset_frames`/`duration_frames`，Space 的 span 也是帧。
  若用 tick 定位，span 随 tempo 编辑漂移，破坏 §4 "tick warp 与 tempo
  无关"硬约定；v1 不做 time-stretch（DAW 的 musical/linear 之辩以
  "帧域固定"收尾）。导入时经 TempoMap 换算落帧，之后 tempo 编辑不影响。
  音量自动化等介入 = 将来的帧域 Metric 锚 channel（接 v2 帧空间锚）。
- tempo 编辑的 Operation 同步：跨轨拖动 = 两轨各一次 apply_batch，
  `edit_version` 全局每批 +1，客户端两批之间需重读版本；多轨原子入口
  `apply_batches` 待跨轨拖动真做时再加。
- 渲染管线形状向 `CheckRequest -> Artifact[Conflict] -> RenderRequest`
  演进；本轮先做 Snapshot（11.1）+ edit_version 钉（11.5 的钉部分，
  强制校验留给 GenServer 壳）。
- 曲线模块与曲线参数的合并：留待 Audio 落地时一并评（音量自动化即曲线）。
- 在接 Oi（主要是 orchid_stratum）前，不用考虑数据缓存，唯一要考虑的是
  乐句分割。

**Track.Audio 操作集**（实现时展开）：insert/delete/drag/split（右半
`source_offset += split - start`，纯整数帧算术）/trim（拖缘 = Retime +
offset 反向补偿，Track 元素钩子，不进 Operate 通用层）；merge v1 拒绝。
