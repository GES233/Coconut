# Coconut 设计草案：Headless Editor

> 2026-07-29 调研讨论存档。来源：对 Qy 下 tamale / oi / equinox / zongzi /
> zongzi_feasibility 五个项目的调研结论与架构决策。状态：部分实现
> （2026-08-02 更新：Workspace 内核、WarpProvider、TempoMap、桥接层
> Resolve 与 Engine 两段式已落地，逐项进度见第 10 节标注）。

## 1. 定位与选型

coconut 是一个 **Headless Editor**（无 UI 的 SVS 编辑器内核），不是重写这些库：

- **介入机制 = tamale**（`Qy/tamale`）：Space / Op / Anchor / Transport / Patch，
  零依赖纯函数内核，三方合并模型，测试 + JSON 一致性向量齐全。
- **调度引擎 = orchid/oi**（`Qy/Orchid` + `Qy/oi`）：已固化，维护者即本人；
  未来变化只会以新 Executor/Hook 形式出现。直接作为稳定平台依赖，不重写。
- **集成参照 = equinox**（`Qy/equinox`）：domain + kernel 两层（去掉 ui_shell）
  即 headless editor 的骨架；Runner 的"两段式 check + 装配 + Blackboard 增量
  缓存"架构照搬，其中 zongzi Declaration 部分换成 tamale。
- zongzi / zongzi_feasibility 不再直接使用；后者的 Scenario + Measurer
  golden 场景验证台模式移植为 coconut 的验收测试。

## 2. 总体架构

```
接口层（Elixir API / JSON-RPC stdio / CLI / MCP，可扩展）
  → command 翻译 + dispatch（按 workspace_id 路由）
  → Workspace（聚合根，GenServer，单写者，命令全序点）
      tempo_space: Space.t()              # tempo 轨（全工程一条）
      tracks: %{track_id => Space.t()}    # 音符轨
      side: 版本化 tempo 快照 / span 表 / elements_by_id / patches
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
- 平铺约定（待定，倾向宽松）：洞 = 继承前一元素 bpm，且首元素受保护
  不可删除；
- `:tick` provider 对 tempo log 永远返回 identity；tempo Space 自身几乎
  不会被挂锚，其角色是"序列化容器 + log 发生器"；
- 拍号（TimeSig）同模式可做，但 v1 只当侧表数据甚至常量。

## 7. Op 覆盖评估

六 op（Insert/Delete/Split/Merge/Move/Retime）覆盖"顺序、身份、时间"三个
正交轴，音符序列 + 曲线参数的编辑需求为最小闭集：

- 纯内容编辑（歌词/音素/曲线控制点）**不落 op**，只写侧表，走 Patch/digest
  语义轴；
- 撤销/重做 = 追加逆批次（append-only，不写回滚）——inverse batch 生成
  逻辑需自写；
- 跨轨拖动 = 源 Space Delete + 目标 Space Insert，锚判死由策略层重挂
  （"Relocation is policy, not transport"；死 patch 在 `side.dead_patches`
  等策略层收取）；
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
3. 首发 channel 清单——方向已定（2026-08-02）：抽象为 `Coconut.Channel`
   behaviour，不写死；首发候选音素 / 音素时长 / 音高（对齐 DiffSinger 的
   tokens/durations/f0 三路模型输入），每 channel 一个 adapter：warp_payload
   + digest 投影，是工作量乘数；
4. API 边界形状：首发建议 Elixir API + JSON-RPC/stdio + CLI 三件套，
   MCP 可后加；渲染为长任务（check 同步一票否决，render 异步 job + 事件）；
5. 持久化：工程文件落盘与否（equinox 的 Pickle codec 可参考）。

## 10. 实施顺序建议

1. Workspace 纯函数内核：lowering + transport（命令流第 2、4 步）——已完成
   （`Coconut.Workspace` / `Coconut.Operate`，写时 transport + 死 patch 坟场）；
2. golden 场景验证台（移植 zongzi_feasibility 的 Scenario/Measurer 模式，
   先翻 G-INT 家族）——未开始；
3. tamale 接入 + warp_provider（:tick 非 ripple 版）——已完成
   （`Coconut.WarpProvider`）；
4. Tempo Track Space + TempoMap fold——已完成（`Coconut.Score.Tempo` /
   `TempoMap`，bpm 在 lower 时归一化为 milli-bpm）；
5. 桥接 + Engine 两段式（check/render）——部分完成：`Coconut.Resolve` +
   `Coconut.Engine` behaviour + `Coconut.Engines.Mock` 已落地；channel 注册表
   （`Coconut.Channel` behaviour + 内置 `Channel.Lyric`）与全局参数闸门
   （`Request.globals` + `info` 声明校验）已落地；首个真实引擎
   `Coconut.Engines.DiffSinger` 已落地（Python worker 经 NDJSON stdio，
   globals 已接入）；orchid/oi 真实接入
   未开始（`Coconut.Engines.OrchidAdapter` 仅占位）；pitch override 已全链路
   打通（`Channel.Pitch` → `{:port, note_id, :pitch}` → adapter 秒域曲线 →
   worker 帧域 pitch_in/retake）；Encoder 契约 + Literal 已落地（phrase
   粒度、逐轨调用、token 形状引擎自定义；真实字典编码器由引擎开发者
   实现）；dur override 已接入（`Channel.Duration` → 钉音素帧数，未钉
   按比例吸收；顺带修债：ph_dur 逐 word 归一到记谱帧数，渲染长度不再
   偏离乐谱）；
6. GenServer 壳 + 接口层（JSON-RPC/stdio 优先）——未开始（Workspace 目前
   仍是纯模块）；
7. 帧空间锚 + tempo 对组合（v2）——未开始。

工作量估计：约 3–4 周（单人），风险集中在 Caller 义务（warp 构造、
digest 投影、float 归一化）与隐式约定密集，而非代码量。
