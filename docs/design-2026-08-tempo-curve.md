# 设计：速度曲线（Tempo Curve）编辑投影与 bake 边界（2026-08-05）

> 前置文档：`design-2026-07-editor-core.md`（§4 时间基准硬约定、§6 Tempo Track）、
> `design-2026-08-orchid-intervention.md`。
> 本文档拍板"渐速/渐慢"的落地路径：**Step 为骨、曲线为皮、bake 为界**——
> 内核只认阶梯 tempo 事件，曲线是适配层的编辑投影，经确定性 bake 落到阶梯。
>
> 2026-08-07 定位注记：本设计（语义手势 → 确定性 bake → 一个 op 批次）是
> "user intervention as first-class" 定位在 tempo 域的实例。

## 1. 背景与约束

- §4 硬约定：tempo 只支持阶梯；Warp 段是有理数端点的线性段，ramp 的曲线
  无法精确表达，会破坏 digest 零容忍比对。此约定锁的是**结构层**
  （tick/warp/digest），不锁消费层。
- 行业调研（2026-08-05 核实）：SMF 的 tempo 只有阶梯事件（meta 0x51），
  任何 DAW 的 ramp 导出 MIDI 都必须离散化；SynthV 比本约定更保守——
  曲速点限四分音符网格、BPM 限整数、无 ramp。coconut 的 milli-bpm +
  任意 tick 布点已是同类中最细。
- 结论：渐速需求不由内核承接，由"曲线投影 → 确定性 bake → 阶梯规范"
  这层适配层抽象承接。

## 2. 分层职责（拍板）

| 层 | 职责 | 改动 |
|---|---|---|
| 内核（tamale / Workspace / TempoMap / digest / warp / 序列化） | 只见 step 事件（整数 tick + 整数 milli-bpm） | **零改动** |
| 适配层（新增） | 曲线 schema、编辑手势、bake 算法、stale 规则 | 本文档主体 |
| 引擎消费层 | 密集阶梯的渲染侧平滑；有真实接线需求后再实现消费点插值 | 不回流内核 |

编辑侧拟合（bake）与渲染侧拟合（平滑）相互独立：前者产出规范数据、要
确定性；后者只是消费点插值、怎么舒服怎么来。

## 3. 编辑模型（拍板：语义手势为主）

- v1 用户操作是**语义手势**而非自由曲线：选一个 tick 区段 → 插入渐速/
  渐慢 → 给起点、终点 BPM 与一个 easing 形状。形状 v1 闭集：
  `:linear | :ease_in | :ease_out | :s_curve`。
- 自由手绘曲线（控制点 + 插值模式）为 v2 非目标；需要精细 sculpting 的
  用户在 bake 后直接改 step 点（触发 §6 stale 规则）。
- **bake 时机 = 手势提交**：拖动过程中不 bake（op log 防爆、撤销不碎）；
  一次手势提交 bake 一次，产出**一个 op 批次**——原子、可单次撤销、
  digest 只跳一次。

## 4. 插值值域（拍板：log-BPM 域）

- tempo 感知是比值性的：100→120 与 50→60 听感相同。BPM 域线性插值的
  渐速前慢后急；**log-BPM 域线性插值才是听感均匀的 accel/rit**。
- 所有形状（含 easing）在 log 域求值，bake 输出时量化回整数 milli-bpm。
- 量化为 bake 内唯一舍入点：`round half even` 到 milli-bpm，规则写死、
  跨语言可复现（对照 §4 微秒纪律）。

## 5. bake 算法 v1（拍板：固定网格）

- 网格粒度可选 `:beat`（每拍）或 `:half_beat`，段内统一，位置对齐 tpqn
  网格。`grid: :beat` 与 SMF 导出、SynthV 四分网格约束天然对齐，互操作
  零损耗。
- **不用自适应布点**（RDP 式误差驱动）的理由——digest 稳定性：
  固定网格下曲线微调只改值、不动点位置，op 批次小、锚冲击局部化；
  自适应拟合下曲线动一点全段点重排，op 批次大、锚大面积 re-anchor。
  自适应降为 v2 优化项，且若做，整段重 bake 作为一个手势提交。
- **确定性是命门**：同一曲线 + 同一参数 + 同一算法版本 → 逐比特相同的
  step 序列。算法版本号进工程文件；**加载工程永不自动重 bake**——落盘
  的 step 是权威，版本不匹配只标记 stale（§6），不偷算。
- 误差界验收：milli-bpm 量化误差 ≤ 0.0005 BPM/步；整段经 `TempoMap`
  换算的秒域累积偏差 ≤ 容差（容差值在实现时按 grid 标定并写入测试）。

## 6. 旁挂元数据 schema 与 stale 规则（拍板）

- 曲线源数据挂 tempo 轨的**侧表**（不进 digest、不落 op、不参与
  transport——与"纯内容编辑走侧表"先例同构）：

```
%{range: {start_tick, end_tick},
  shape: :linear | :ease_in | :ease_out | :s_curve,
  from_mbpm: pos_integer, to_mbpm: pos_integer,
  bake: %{algo: :grid, grid: :beat | :half_beat, version: pos_integer}}
```

- **stale 规则（简单狠）**：区段内 step 被曲线以外的手势触碰 → 该条
  元数据整条失效；重新打开曲线编辑器时按现有 step 反推初始 ramp
  （首尾值 + `:linear`），不做 step→曲线的自动同步（双向映射是坑）。
- step 永远是权威；曲线元数据只是"这段是怎么来的"的编辑辅助。

**序列化落点（已定 2026-08-05）**：侧表不落 Track 内部，挂 Workspace
存档的独立可选 key `tempo_ramps: [ramp_dump]`（tempo 轨全局唯一，平铺
list 即可）——Track struct/codec 零改动，与 §2"内核零改动"严格一致。
§6 援引的"纯内容编辑走侧表"先例是元素级侧表（随 `elements_by_id` 走），
ramp 是区段级数据、不依附单一 element id、生命周期独立（stale 整条
失效），先例套不上，故走工程级区段。配套约定：

- load 逐条走 `Tempo.Ramp.new/1` 校验（shape/grid 闭集、正整数 mbpm），
  未知 shape 按 pickle 惯例 loud error；缺 key = 空表，老存档天然兼容。
- 两个版本号各管各的：envelope `version` 管格式迁移（`Pickle.File`
  钩子），`bake.version` 管算法版本、纯记录——§5"加载永不自动重 bake"
  已保证 load 时它不触发任何计算；v2 自适应布点上线后旧档原样加载，
  仅在重新提交手势时用新算法重 bake。
- `tempo_ramps` 与 `patches`/`elements_by_id` 平级、不进 digest——
  step 相同而 ramp 元数据不同的两个工程 digest 一致。
- stale 标记不落盘：存档只存原始 ramp 条目，stale 判定是加载后适配层
  的运行时比对（元数据比对非 bake，不与"加载零计算"冲突）。
- 手势层无任何 codec：手势提交即 bake 成普通 tempo op 批次，op log
  只见六 op（`Pickle.Op` 已覆盖），undo 单元是 baked batch 而非手势。

## 7. 查询配套（已落地）

- 选区经过时间：`TempoMap.duration_sec/3`（零宽/反向区段返回 `0.0`，
  与 `slice/3` 空区段语义对齐）与 `Workspace.region_duration_sec/3`
  （透传 `:missing_tempo_track`，引擎走自有回退）——本文档定稿时同步实现，
  见 `lib/coconut/score/tempo_map.ex`、`lib/coconut/workspace.ex`。

## 8. UI 共存（一车道两层）

- 曲线模式：平滑曲线为前景，bake 出的 step 以半透明阶梯衬底——
  用户永远看到内核真正看到的东西。
- step 模式：拖 bake 生成的点触发 stale 提示（"此区段由速度曲线生成，
  编辑将脱离曲线"）。

## 9. 模块形态（拟定）

- `Coconut.Score.Tempo.Ramp`：曲线 schema（§6 形状）+ cast/校验。
- `Coconut.Score.Tempo.Ramp.Bake`：`bake(ramp, tpqn) :: [{tick, mbpm}]`，
  纯函数、确定性、版本化。
- 手势入口挂 `Operate`（新 operation 或 CoreComponents 扩展），输出普通
  tempo 元素批次走 `apply_batch`——内核不感知曲线的存在。

## 10. v1 收口与非目标

- 收口：语义手势（§3）+ log 域插值（§4）+ 固定网格 bake（§5）+
  侧表元数据与 stale 规则（§6）+ 选区经过时间查询（§7，已落地）。
- 非目标：自由手绘曲线、自适应布点（均 v2）；线性 tempo 插值进 warp
  （永不，§4 硬约定）；MIDI 导入反推曲线（v2）。
- 测试基准：固定 ramp fixture 的黄金 step 序列；bake 两次逐比特一致；
  秒域误差界测试；stale 规则测试（旁改 step → 元数据失效）。
