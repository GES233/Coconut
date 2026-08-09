# Coconut 设计草案：引擎无关编辑器内核（Intervention First-class）

> 2026-07-29 调研讨论存档。来源：对 Qy 下 tamale / oi / equinox / zongzi /
> zongzi_feasibility 五个项目的调研结论与架构决策。状态：部分实现
> （2026-08-03 更新：Track-ification（§11.1–11.3、11.8）、拍号入 Workspace、
> golden 场景最小集已落地，逐项进度见第 10 节标注）。
>
> 2026-08-07 定位注记：项目定位由 "A headless SVS Editor" 更新为
> "An engine-agnostic editor core that treats user intervention as
> first-class"（README 同步）；本文档随之更名（旧文件名
> design-2026-07-headless-editor.md，原标题"Headless Editor"），§1 定位段、
> §3 标题与框架已重写，其余存档段落保留当时表述。下述 08-06 迁移注记的
> 模块映射同样适用于文件路径（如 `lib/coconut/resolve.ex` →
> `lib/coconut/render/resolve.ex`、`lib/coconut/engine.ex` →
> `lib/coconut/render/engine.ex`），正文/补记中的旧路径不再有效。
> 
> 2026-08-06 迁移注记：模块名已按目录命名空间重构——`edit/`、`render/` 目录
> 下的实现统一加 `Coconut.Edit.` / `Coconut.Render.` 前缀。新旧对照：
> `Coconut.Patch` → `Coconut.Edit.Patch`；`Coconut.Track` → `Coconut.Edit.Track`
> （`Track.Tempo`/`Track.Vocal` 随之 `Edit.Track.*`）；`Coconut.WarpProvider` →
> `Coconut.Edit.WarpProvider`；`Coconut.Workspace` → `Coconut.Edit.Workspace`；
> `Coconut.Channel` → `Coconut.Render.Channel`；`Coconut.Encoder` →
> `Coconut.Render.Encoder`；`Coconut.Engine` → `Coconut.Render.Engine`
> （`Engine.Artifact/Request/Snapshot` 随之）；`Coconut.Resolve` →
> `Coconut.Render.Resolve`；`Operate` → `Coconut.Edit.Operation`
> （`Operations.*` → `Edit.Operations.*`）。本文档补记/存档/已定段落保留
> 当时定名；裸词 Workspace/Track/Resolve/Engine 为架构概念名。

## 1. 定位与选型

coconut 是一个**引擎无关（engine-agnostic）的编辑器内核，将用户干预
（intervention）视为一等公民**（2026-08-07 定位更新；旧定位"无 UI 的 SVS
编辑器内核"，SVS 降为首发应用域而非定义）。干预——Patch 挂载、写时
transport、digest 零容差比对、两段式否决——是内核的主轴，渲染引擎只是
其下游消费者之一。它不是重写这些库：

- **干预机制 = tamale**（`Qy/tamale`）：Space / Op / Anchor / Transport / Patch，
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
      5. 存活集合 → Resolve → Snapshot/Request（钉 edit_version，§11.1/§11.5）
         → Engine check/render（异步 job，事件回推；产物为 Artifact）
```

术语对齐：**Workspace（工程）→ Track（轨 = 一个 Space + 侧表）→ Element
（音符 / tempo 事件）**。不使用 "Timeline" 一词（避免与 zongzi 旧机制串味）。

## 3. 干预裁决层（`Coconut.Render.Resolve`；旧称"桥接层"）

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

tamale 的干预模型与引擎/调度器范式不同，Resolve 显式隔离两者——它是干预
链路的裁决层，而非某个渲染后端的适配器（2026-08-07 定位更新：本节旧称
"桥接层"，原表述"tamale 与 oi 范式不同"预设了 oi 终点，与 engine-agnostic
定位不符）。职责只三条：

1. tamale transport/resolve 结果 → 折叠为引擎无关的中间形状
   `%{port_ref => %{input: value}}`（存活干预转 `:override`、按 producer
   端口 keying 的 oi data 翻译发生在 dispatch 边界，见
   design-2026-08-orchid-intervention.md §2/§4）；
2. conflict（含 clip / ambiguous）全量聚合为一票否决（verdict
   `%{passed: false, entries}`；equinox Runner 语义照搬）；
3. 反向：用户编辑手势 → tamale Op 脚本。

参照：equinox `Runner.resolve_units` / `fold_resolved`。

## 4. 时间基准（硬约定）

- **tick = 结构层权威坐标**：音符、干预锚都挂 tick（Metric 或 Ordinal）。
- **帧/采样点 = 引擎层坐标**：digest 投影与渲染窗口使用，整数帧号。
- **秒只允许以整数微秒出现在导出/展示边界**。float 在所有内核边界被拒绝
  （tamale Coord 学说），归一化在适配层完成，舍入只发生在最终消费点。
- **tempo 结构层只支持阶梯（step），不支持线性 ramp**——Warp 段是有理数端点的
  线性段，ramp 的二次曲线无法精确表达，会破坏 digest 零容忍比对。
  渐速靠加密 tempo 点逼近，采样端拟合。
- tick↔帧换算收敛到唯一一处（warp_provider / Resolve 采样处），
  zongzi_feasibility 的教训：跨语言舍入一致性是隐形地雷。

> 2026-08-05 补记：渐速（ramp）的落地路径已定——见
> `design-2026-08-tempo-curve.md`。Step 为骨、曲线为皮、bake 为界：
> 内核仍只见阶梯，曲线是适配层编辑投影，经确定性 bake 落到阶梯事件；
> 本条硬约定不变。
>
> 2026-08-07 补记：`Tempo.Linear` 已作为 `Tempo.Segment` 实现落地
> （`lib/coconut/score/tempo.ex`）。本条约定锁的是**结构层**——tempo 轨
> 只产 Step 事件（`Track.Tempo.tempo_events/1`），op / digest / warp 只见
> 阶梯；Linear 属消费层插值设施，渲染侧消费点尚未接线（见 tempo-curve
> 文档 §2）。

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
5. provider 分派（2026-08-06 对齐）：构造点（写时 `Workspace` / 检查时
   `Resolve`）经 `WarpProvider.for_coord/3` 按轨的 `coord_domain/0`
   查 core 分派表构造 closure，`supported_coords/0` 从同一张表推导
   （`Patch.new` 挂载守卫随之自动放开，不再散落硬编码）；无 builder
   的 coord 返回 nil，走 `transport_patches` 既有 nil 语义（Ordinal
   恒等 transport，Metric 以 `:warp_provider_required` 判死而非
   clause 缺失崩溃）。帧 builder 的入参签名（需 tempo map，与本表
   (spans, patches) 形状不同质）随第 4 条落地时再定；锚 coord 与轨
   domain 的一致性校验仍挂在 attach_patch 待办（Audio 落地项）。

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
  散拍子 `:san` 暂不考虑。补记（2026-08-09）：`time_sigs` 的变更
  从 `Workspace.update/2` 切出为 `set_time_sigs/2` 纯函数（复用
  `validate/1` 的合法性把关），入史为 `{:set_time_sigs, events}`
  轻量边（§12.4）——不开 track 的裁决不动（无 Space、无锚），但
  中途变拍是乐谱手势，走 `update/2` 会被 §12.4 划出历史、不可
  撤销，故单开一条边；边存全量新列表（极小），replay = 调
  `set_time_sigs/2`。`tpqn` 仍随 `update/2` 出局。

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

1. warp-provider 参考实现 → 已落地（`Coconut.Edit.WarpProvider`，本设计第 5 节的
   v1 非 ripple 版）；
2. `diff(old, new)` 回退适配器（编辑来源是状态而非 op 时需要，如文件导入）
   ——启发式集中在这一个函数；
3. chunked digest helper；
4. undo → 已拍板（2026-08-07）：改采快照栈，见 §12；inverse batch
   方案（含 tamale seen 放宽）评审后否决，存档于分支；
5. 跨 Space 重挂策略（跨轨拖动）。

**缺口展开（补记 2026-08-05）**：

- **2. diff 适配器**：正常路径是手势 → op 批次；文件导入（MIDI/UST）、
  外部整轨改写、整块粘贴只给"改完的状态"，需从新旧元素快照反推六 op
  序列。启发式 = 身份对齐（导入格式无 coconut id，按复合键还是位置贪心）
  + 顺序/时间/数量变化归类；"集中在这一个函数"指不确定性收口一处，
  其余路径保持纯 op。未拍板：身份匹配键与保守策略（宁可 Delete+Insert
  不错认 Move，还是反过来）。落点为 `Operate` 同级独立模块，输出标准
  `ops + side_changes` 走同一 `apply_batch` 管道；头号用户 MIDI 导入是
  v2 项，v1 可欠。
- **3. chunked digest helper**：`Tamale.Digest.digest/1` 一次性吃完整
  canonical term，整轨投影大时物化成本高；helper 为分块流式 digest。
  命门：分块结果必须与一次性 digest **逐比特一致**，否则同一内容的
  `base_digest` 因调用路径分裂、patch 存活判定崩——故方案围着
  canonical 编码可分段拼接这个不变量设计，不是简单包 `:crypto` 的
  init/update/final。用途排序：channel digest 投影 > voicebank digest
  实算（v1 只存不算）> 工程级 digest。落点 tamale 侧为主。
- **4. inverse batch 生成**：撤销 = 追加逆批次（append-only）已定，缺
  生成逻辑。六 op 的逆分三档：自带可逆（`Retime` 换 before/after；
  `Split`↔`Merge` 互逆）；结构可逆（`Insert`→`Delete`；`Move` 回原
  邻居）；**需前状态**（`Delete` 的逆要恢复元素内容与 span，op 本身
  不含——故 inverse 必须在 lower/apply 当下同步捕获，不能事后从 log
  推）。连带：`side_changes` 同逆；跨轨批次需两轨同撤（与 5 纠缠）。
  红利：撤销只是又一批 op，patch 锚沿新 log 自然 transport。undo
  历史存哪（Workspace 字段 vs GenServer 壳状态）与接口层一起排。
  （补记 2026-08-07：已拍板并改采快照栈——本段的 inverse batch 设计
  （含 tamale seen 放宽）评审后否决，存档于分支；落地方案见 §12。）
- **5. 跨 Space 重挂**：跨轨拖动 = A 轨 Delete + B 轨 Insert，但 id 是
  Space 级身份——沿用同 id 则 A 轨钉着它的 patch 全 terminal；换新
  id 则用户感知身份断裂、曲线类 patch 照样全灭。选项：a) 新 id +
  patch 不迁移（简单狠）；b) 同 id + patch 跨轨打捞重挂；c) 复合手势
  lowering 成两轨批次 + patch 迁移表。结构牵连：`apply_batch/5` 目前
  单轨，跨轨需两轨原子提交（单 version 检查 + 两条 log），并反过来
  决定 undo 历史粒度。tamale 不动，`Operate` 加复合手势入口。
- **排期依赖**：4 与 5 互相纠缠（捕获时机、跨轨原子提交+撤销），相邻
  排期；2 等文件导入排期；3 等投影规模真的疼了再做。

## 9. 前置条件（动手前需定）

1. 引擎面：驱动的引擎是谁（决定 Engine behaviour 与 digest 投影实现）
   ——已定（2026-08-02）：首发 DiffSinger（OpenUTAU 格式声库），经
   `Coconut.Engines.DiffSinger` + `lib/coconut/engines/diffsinger/worker.py`（NDJSON stdio）
   接入；UTAU classic 备选，歌词→请求 token 的 Encoder 层单开。
   （2026-08-07 定位注记：engine-agnostic 定位下，引擎面边界由 Engine /
   Channel / Encoder 三契约定义，DiffSinger 是契约的首个参考实现而非
   引擎面本身；）
2. 坐标基准：已定（tick 权威 + 帧 + 微秒，见第 4 节）；
3. 首发 channel 清单——已定（2026-08-02）：抽象为 `Coconut.Channel`
   behaviour，不写死；首发音素 / 音素时长 / 音高三路已落地
   （`Engines.Channels.Lyric` / `Duration` / `Pitch`，对齐 DiffSinger 的
   tokens/durations/f0 三路模型输入），每 channel 一个 adapter：warp_payload
   + digest 投影，是工作量乘数；
4. API 边界形状：首发建议 Elixir API + JSON-RPC/stdio + CLI 三件套，
   MCP 可后加；渲染为长任务（check 同步一票否决，render 异步 job + 事件）；
5. 持久化：工程文件落盘与否（equinox 的 Pickle codec 可参考）。
   ——已定（2026-08-05）：持久化走 Pickle codec（equinox 惯例移植，
   `lib/coconut/pickle*.ex`）；Project 字段形状拍板：engine/settings/assets
   保留 nil，voicebank = `%{name, engine, digest}` 签名；文件外壳为
   `%{format, version, project}` 信封 + `term_to_binary`。

## 10. 实施顺序建议

1. Workspace 纯函数内核：lowering + transport（命令流第 2、4 步）——已完成
   （`Coconut.Edit.Workspace` / `Coconut.Edit.Operation`，写时 transport + 死 patch 坟场）；
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
   （`Coconut.Edit.WarpProvider`）；
4. Tempo Track Space + TempoMap fold——已完成（`Coconut.Score.Tempo` /
   `TempoMap`，bpm 在 lower 时归一化为 milli-bpm）；
5. 桥接 + Engine 两段式（check/render）——部分完成：`Coconut.Render.Resolve` +
   `Coconut.Render.Engine` behaviour + `Coconut.Engines.Mock` 已落地；channel 注册表
   （`Coconut.Render.Channel` behaviour + 内置 `Engines.Channels.Lyric`）与全局参数闸门
   （`Request.globals` + `info` 声明校验）已落地；首个真实引擎
   `Coconut.Engines.DiffSinger` 已落地（Python worker 经 NDJSON stdio，
   globals 已接入）；orchid/oi 真实接入
   未开始（2026-08-09 起 adapter 独立成包、树内占位已删，见
   design-2026-08-orchid-intervention.md §3.3/§4）；pitch override 已全链路
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
随 `Coconut.Edit.Track` 下沉（tempos_by_version 占位随之消失，v2 变 tempo 需要时
再议）；`Track.truncate/2` + `Workspace.truncate/3` 已接入同步裁剪
（span 快照保留 cut 处最新一份作 baseline，warp 的 `spans_at(v-1)` 需要它）。

**现象**（原问题，存档）：`Side` 一个 struct 装 spans_by_version / elements_by_id / patches
/ dead_patches / tempos_by_version（占位从未写入）；`spans_by_version`
无界增长，`Space.truncate` 的"同步裁剪"未实现。

**方向**：启用 `tempos_by_version`（变 tempo 时的 transport 锚定需要它）
或删字段；接入 truncate 裁剪；side 拆分命名（乐谱侧表 / 干预侧表）。

### 11.4 port_ref 语义（DTO 化已推迟 2026-08-04；现状仍为 `{:port, node, port}`）

**已推迟**：oi 的 PortRef 与本项目 port_ref 同形（`{:port, node, port}`），
DTO 化决议无限期推迟，转换（若做）放在 coconut↔oi 边界；fold 同 port
覆盖问题经 orchid-intervention 文档 §3.2 的聚合规则在 assemble 层事实上
消解，等真出现再议（见该文档 §2/§7）。以下"已定方向"存档保留。

**现象**：`{:port, node, port}` 的 node 位一会是角色名（`:synth`）一会是
音符 id；fold 同 port 后来者**静默**覆盖先来者；端口认领靠各 adapter
模式匹配自觉，无注册机制。

**已定方向**（存档）：port 引用改为显式 DTO（Map 或 Struct，不用位置元组），
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

**补记（2026-08-09）**：钉的形状随 §12.2 定为 History 签发的 cursor
node id（`Snapshot` 加可选 `pin` 字段，裸构造路径留空、行为同今）；
强制校验随壳施工不变。

### 11.6 PortClient 无监督 + key 切换队列污染

**现象**：全局单例 GenServer 不在 supervision tree 下；worker key 变化时
旧 key 的排队请求会落到新 worker（v1 注释妥协）。

**方向**：挂监督树；key 切换时 fail 掉旧队列而非误投（多声部/多声库时
重做）。

### 11.7 毛边（记入 backlog，随用随修）

- 错误词汇两套：`missing_x` / `bad_x` / `unknown_x` 混用，接口层对外前
  统一。
- ~~Operate request 为 6~7 元 tagged tuple，位置参数多；成为 wire format
  前再评。~~ 已解决：request 改为 `Coconut.Edit.Operations.*` struct
  （`Operate` 仅做 dispatch）。
- `Note.to_canonical` 的 key 形状（`%{midi: n}`）是隐性契约：换 tuning
  或改形状 = 全部已挂 patch 的 base_digest 失效。改 canonical 形状视为
  breaking change。
- `Workspace.tempo_map/1` 每次现编 TempoMap；大工程下考虑缓存
  （与 tempos_by_version 一并想）。
- `Engine.Snapshot.from_workspace/1` 的 `tracks` 只含 `ws.tracks`，
  tempo 轨缺席——引擎只能拿到编译后的 `tempo_map`，拿不到原始 tempo
  事件/元素（未来 tempo ramp 干预、tempo 编辑的 patch 投影都会卡在这）；
  当前 DiffSinger 用不到，v2 定 tempo 干预时再补 track view。

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
- **Track 加 `name` 字段（2026-08-09 定）**：实例显示名，纯
  annotation——可变、可重复（不做唯一性校验）、可空（`nil`）；
  id 不可变维持不变，路由/锚/patch/版本钉永远只用 id。与
  `Pickle.Registry` 的轨型逻辑名是两个命名空间（实例显示名 vs
  轨型名；后者是存档格式契约），判型永远按能力、绝不按 name。
  rename 是 mutation，入史为 `{:rename_track, track_id, name}` 边
  （§12.4）。Pickle：`name` 作可选字段进 dump，旧档缺失 load 为
  `nil`——首个可选字段先例：格式兼容走"容忍缺失"档，而非版本号。
- behaviour 回调（克制，不含 Audio 占位共 6 个）：`coord_domain/0`、
  `cast_element/3`、`edit_element/2`、`validate_gesture/3`、
  `split_inherit/2`、`view/1`。`edit_element/2`（2026-08-03 补）：
  内容编辑的合并+重铸，`edit_note` lowering 经它一步写回（原 `:touch`
  stub 退役，调用方不再各自扮演 cast 义务）。
- 可选能力（2026-08-06 收编）：`tempo_events/1`（`:tempo_derive`）与
  `dump_element/1`+`load_element/1`（`:element_codec`，成对探测——
  只导出一半视同不具备）统一由 `Track.supports?/2` 嗅探，回调名不再
  散落各调用点；配套内嵌 behaviour（`Track.TempoDerive` /
  `Track.ElementCodec`）给编译期警告，但绑定仍按导出不按声明。
  插件轨型（`Track.Audio`、宿主自定义）只需实现回调 + 注册
  `Pickle.Registry`，能力自动被发现。
- 首发模块：`Track.Vocal`（Note 元素，tick 域）、`Track.Tempo`（bpm 裸 map，
  tick 域，首元素删除保护落 validate_gesture）。`Track.Audio` 紧随其后，
  `Track.Synth` 留位（参数面比 Vocal 简单，不预留实现）。
- **Audio = 帧域轨道（已定）**：clip 的位置与内容都在帧/采样域——
  `source_offset_frames`/`duration_frames`，Space 的 span 也是帧。
  若用 tick 定位，span 随 tempo 编辑漂移，破坏 §4 "tick warp 与 tempo
  无关"硬约定；v1 不做 time-stretch（DAW 的 musical/linear 之辩以
  "帧域固定"收尾）。导入时经 TempoMap 换算落帧，之后 tempo 编辑不影响。
  音量自动化等干预 = 将来的帧域 Metric 锚 channel（接 v2 帧空间锚）。
- tempo 编辑的 Operation 同步：跨轨拖动 = 两轨各一次 apply_batch，
  `edit_version` 全局每批 +1，客户端两批之间需重读版本；多轨原子入口
  `apply_batches` 待跨轨拖动真做时再加。
- 渲染管线形状向 `CheckRequest -> Artifact[Conflict] -> RenderRequest`
  演进；本轮先做 Snapshot（11.1）+ edit_version 钉（11.5 的钉部分，
  强制校验留给 GenServer 壳）。
- 曲线模块与曲线参数的合并：已了断（2026-08-07）——Curve 收编为适配层
  曲线参数化库，payload 为控制点容器，rasterize 在消费边界；见
  design-2026-08-orchid-intervention.md §6.3。音量自动化即曲线，Audio
  落地时复用同一套。
- 在接 Oi（主要是 orchid_stratum）前，不用考虑数据缓存，唯一要考虑的是
  乐句分割。

**Track.Audio 操作集**（实现时展开）：insert/delete/drag/split（右半
`source_offset += split - start`，纯整数帧算术）/trim（拖缘 = Retime +
offset 反向补偿，Track 元素钩子，不进 Operate 通用层）；merge v1 拒绝。

## 12. Undo/Redo：Op 树 + 检查点（拍板 2026-08-09，已落地同日）

承接 §8 缺口 4。方案演进：inverse batch（追加逆批次）曾完整设计
（含 tamale seen 放宽），评审后否决、存档于分支；快照栈（双栈
past/future + 全量 Workspace 快照 + epoch 版本钉）拍板于
2026-08-07、未施工，经 2026-08-09 评审由本方案取代。快照栈存档
要点：机制最少、逐比特恢复靠构造保证。被取代的原因——`future`
清空丢分支（分支试错是创作场景的真实需求）、放弃审计叙事、
`epoch` 污染 Workspace 纯度（update 拒改 / Pickle 排除 / 测试断言
例外三处税）。其快照机制被本方案吸收为检查点（§12.3）。

### 12.1 模型与语义

- History = 一棵 Op 树 + cursor：节点 = 状态（惰性物化），边 = 一条
  **已解析的写记录**（§12.4）。`present` 增量维护——写只发生在
  cursor，present = 旧 present + apply 一条边，O(1)、无 refold。
- 检查点：节点按需挂 Workspace 快照——**每 K 条边一个 + 每个分支
  节点一个**（只挂分支点不够：长链无分支时 fold 无界）。cursor 跳跃
  = 从目标后方最近检查点 fold 边序列，fold 长度 ≤ K。BEAM 结构共享
  使检查点近似免费。
- 逐比特等价的来源改变：快照栈靠构造保证，本方案靠**重放等价**
  证明——核心不变量：任意 cursor 位置 `replay(最近检查点, 边路径)`
  == 实况 `present`。执法者为 §12.6 的核心 property。
- 新手势、新写路径自动获得 undo：replay 只有正向 apply，无
  per-gesture 逆逻辑税（diff 适配器、Tempo.Ramp 均免费）；跨轨同撤
  （§8 缺口 5）= 一条边记录多轨批次（将来的 `apply_batches`）。
- **审计叙事回归**：树即完整手势史（含分支），快照栈放弃的叙事
  拿回；op log 语义不变（undo 事件不进 log，叙事在 History 边而非
  log）。每条边生成确定性 gesture label（`Operations.*` struct 的
  纯函数），供历史面板/分支 UI；LLM 语义 rollup 留壳层可选装饰
  （输入 = 分支的 label 序列），不进 lib、不进写路径。

### 12.2 遍历语义与版本钉

- 每个节点发 History 内单调递增 `seq`（创建序 = 时间序）；
  timestamp 仅 UI 展示、不参与排序（免疫时钟回拨与同毫秒撞号）。
- 默认 undo/redo = **全局 seq 序遍历**（Vim `g-`/`g+` 语义）：undo
  = seq 前一节点，redo = 后一节点；**树结构不参与导航**，仅用于
  物化时定位检查点路径，导航只需一个 seq 索引。
- 行为拍板（反直觉点，将来的 UI 提示要写明）：undo 扫到分支边界
  会跨分支"瞬移"——主干 1–5、undo 到 3、写 6'7' 后，从 7' 连续
  undo = 7'→6'→5→4→3；全量 undo 把每个已创建状态恰好访问一次，
  任何状态永不丢失。否决项：访问日志序（浏览器后退式）——重复
  访问同一状态，旧分支在深 undo 中反而难达。
- 红利：v1 不需要任何分支选择 UI——树存储、线性交互。
- 版本钉：兄弟分支路径等长即撞 `edit_version`，撞号面比
  "undo 重写"更宽，epoch 方案（旧 §12.2，见上存档）取消。A2 下
  History 是所有写的唯一入口（内在纪律，非可选惯例），钉 =
  History 签发的 **cursor node id**；§11.5 的强制校验 = 壳比对
  client 钉 == cursor node id。`Snapshot` 加可选 `pin` 字段：壳经
  `History.current/1` 构造 Request 时填入 node id；裸
  `Snapshot.from_workspace/1`（lib 内部与测试用）留空、只钉
  `edit_version`，行为同今。`apply_batch` 的 `check_version` 不动
  （聚合内版本锁仍在），跨分支防误写由 History 写入口完成。
  Workspace 保持纯值、零例外字段；Pickle 字段列表不动。

### 12.3 放置、形状与生命周期

- 落点：独立包装 `Coconut.Edit.History`——树与检查点嵌进
  Workspace 需每层剥壳、语义混；包装层干净，且是壳（§10.6）的
  天然持有物。形状：`%{nodes, cursor, seq, present}`；node =
  `{id, seq, parent, children, checkpoint?, record, label,
  timestamp}`（root 无 record、自带检查点；边记录挂在它产生的
  子节点上）。
- History 同时补上 lib 缺失的写组合层：写入口 = validate → lower
  → 记边 → apply_batch → 更新 present。
- 生命周期：session-scoped，工程重载历史为空（编辑器惯例）；
  `Pickle.Workspace` 按字段显式 dump，天然不触及 History。
- 内存与修剪：总量 = O(边数) + O(检查点)。上限按边数（v1 常量，
  如 5000），超限**压扁 trunk**：最旧前缀路径合成一个检查点节点
  （squash），中间边丢弃，seq 索引变稀疏但保持递增（优于按节点
  LRU：单一规则、对分支无偏心）。
- K（检查点间距）v1 常量（如 100 边），knob 化留壳层。
- truncate（§11.3）交互：语义安全——检查点是物化状态，不读旧
  log/旧 spans，truncate 自身不入史（维护操作）。注意内存：旧检查
  点会**钉住被 truncate 前的 log/spans 不被 GC**，truncate 的收益
  要等相关检查点被 squash 掉才兑现。

### 12.4 边纪律（入史写路径）

边上挂 Op 把 undo 从数据保留技巧变成复制协议，三条硬纪律：

1. **边上存解析后的记录，不是原始请求**：apply_batch 系 = lowered
   `ops + side_changes`；`attach_patch` 系 = **mint 后的 patch**
   （id 落定）；`add_track` 系 = **构造完成的 Track**（id 落定）；
   轻量字段边 = **全量新值**（rename / set_time_sigs）。replay 只跑
   确定性 apply，不再 lower/mint/构造——`attach_patch` 的随机 id
   minting 因此对重放无害。
2. **任何改状态的函数，要么是一条边，要么明确出局**：
   - 入史：`apply_batch`（六手势及未来一切批次，含跨轨）；
     `attach_patch` / `attach_patches`（现状不 bump `edit_version`，
     不变）。
   - **轨道结构写**入史为两种边：`{:add_track, track}`（存完整
     Track；新建轨 = `{id, module}` + 空侧表，极小）与
     `{:remove_track, track_id}`。前向 replay = tracks map 的
     put/delete；**边里不存尸体**——被删轨道的全部内容由该边
     之前的边重建（undo 过删除点 = cursor 回到删除前，轨道自然
     在）；squash 后早期状态本就不可达，一致。tempo 轨是独立
     字段（§6），不参与增删；`Workspace.new` 带入的初始轨道属
     root 状态，无需边。删非空轨 v1 允许——undo 经 replay 整体
     恢复其 elements / patches / 坟场（DAW 惯例，无重挂语义）。
     增删轨 bump `edit_version`（渲染产物随之变；规则表述：乐谱
     结构变化 bump，干预挂载不 bump）。
   - **轻量字段边**（2026-08-09 定）：`{:rename_track, track_id,
     name}` 与 `{:set_time_sigs, events}`——无 Space 机器，边存
     全量新值，replay = 调对应纯函数。轨道名是 annotation
     （§11.8，rename 可撤销是 DAW 惯例），中途变拍是乐谱手势
     （§6，不可撤销是真实的洞）：二者入史。
   - `take_dead_patches` 清坟场是 mutation（现状名为读取性操作）
     → 记 `consume_dead` 边（带取走的 patch id 列表）。配套：策略
     层消费坟场按 `{patch.id, anchor.at_version}` 幂等去重——同一
     patch 重挂后再死 at_version 不同，单按 id 去重会吞掉第二次
     死亡。
   - `Workspace.update/2`（收缩后只剩 `tpqn` 等工程级字段——
     `time_sigs` 已切出，见上）与 Project 层元数据：v1 声明出局——
     不受逐比特保证、不单独可撤（效果落在后续检查点里）；元数据
     撤销待 Project 层 before/after，另议。
   - 连带：`tracks` 是 Map、无序（`all_tracks` 明言 fold 序非语义）。
     将来 UI 需要轨道排序时，reorder 是新 mutation，同样必须是一条
     边——先记在这里，免得再漏。
3. **重放与实况共用同一 apply**：replay 直接调
   `Workspace.apply_batch` / `attach_patch` / `add_track` /
   `remove_track` / `rename_track` / `set_time_sigs`，禁止 replay
   专用分支（第二种实现 = 发散源）。

### 12.5 API 形状

- `Coconut.Edit.History`：`new/2`（包装现有 ws；opts 为
  `checkpoint_interval` / `max_edges` knob）、`apply/4`（写组合层，
  见 §12.3）、`apply_patch/3` / `apply_patches/3`、`add_track/3` /
  `remove_track/3`（记结构边）、`rename_track/4` / `set_time_sigs/3`
  （记轻量字段边）、`take_dead_patches/1`（记 `consume_dead` 边）、
  `undo/1` / `redo/1` → `{:ok, hist}` | `{:error, :nothing_to_undo |
  :nothing_to_redo}`、`current/1`（present + cursor node id，供壳
  构造 Request 时钉版本）、`state_at/2`（任意存活节点的物化状态，
  树 UI/分支枚举的地基）。写入口 opts 收 `:pin`（不等于当前 cursor
  即 `{:stale_pin, _}`，§12.2 的壳校验）；`apply/4` 另收 `:config`。
- 分支结构 API（子分支枚举等）v1 不暴露——树 UI 是壳层议题，
  届时再加。
- `Workspace` 需新增公开纯函数 `add_track/2` / `remove_track/2` /
  `rename_track/3`，并将 `set_time_sigs/2` 从 `update/2` 切出
  （`update/2` 收缩后不再接受 `time_sigs`）：现状无任何公开增删
  轨 API（`put_track` 私有，轨道仅经 `new/1` 与 Pickle 进出）——
  本方案顺带补齐，replay 与实况共用（纪律 3）。除此之外
  Workspace 零改动（无 epoch）；纯函数 API（`validate` / `lower` /
  `apply_batch` / `attach_patch`）不动——History 是组合层，测试
  与将来的壳直接用；lib 内无连锁。
- 边数上限、K 为模块常量；knob 化留壳层。

### 12.6 测试点

- 核心 property：**重放等价**——随机手势序列 + 随机 undo/redo
  游走，任意时刻 `replay(最近检查点, 路径)` 与 `present` 逐比特
  等价（§12.4 纪律 1、2 的执法者；手势池含轨道增删、rename、
  set_time_sigs）。
- 轨道结构边：删非空轨 → undo，其 elements / patches / 坟场随
  replay 整体恢复；增删轨 bump `edit_version`；同分支内向已删
  轨道的写在写入时被拒（`fetch_track` 失败），replay 路径不存在
  该序列。
- 遍历语义：构造分支（写 → undo n → 写），断言全局 seq 序遍历
  顺序（含跨分支"瞬移"用例：7'→6'→5→4→3）；全量 undo 访问每个
  状态恰好一次；新写后 redo 到最新 seq 即止。
- 边纪律：`attach_patch` 序列两次重放逐比特等价（mint 已落定）；
  `consume_dead` round-trip（坟场随 cursor 复活/再消费，幂等去重
  生效）。
- 版本钉：分支/undo 后 cursor node id 全局唯一；client 持旧钉写
  被 History 写入口拒绝。
- 检查点/squash：fold 长度 ≤ K；超限 squash 后最旧状态不可达、
  present 不受影响、seq 保持单调。
- Pickle：dump/load 回归（Workspace 无新字段；重载历史为空；
  Track `name` 为可选字段，旧档缺失 load 为 `nil`）。
- 跨手势混合序列随机 round-trip（旧 §12.6 保留项，断言改为重放
  等价）。
