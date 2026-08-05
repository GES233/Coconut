# 设计：Intervention 层落地与 Orchid/oi 接入（2026-08-04）

> 前置文档：`design-2026-07-headless-editor.md`（§3 桥接层、§11.4 port_ref、§11.5 版本钉）。
> 本文档拍板 intervention 层的落地路径与 orchid 生态的接入方式。

## 1. 背景与现状

coconut 的干预链路已落地到 equinox 集成路径的中段：

- `Coconut.Patch`（anchor + tamale patch + channel）→ `Workspace` 写时 transport
- `Coconut.Resolve.run_check/3`：channel spec 投影 → digest 零容差比对 →
  `fold_resolved` 产出 `%{port_ref => %{input: value}}`
- 三路 channel 已接 DiffSinger：Lyric / Pitch / Duration
  （`lib/coconut/engines/channels/`）

**缺的半层**（对照 equinox `Runner` 的 Compiler + assemble_data）：

1. 渲染管线的 DAG 声明与编译（`Oi.compile`，按图结构缓存）
2. interventions → oi 嵌套 `data:` 的翻译（`{:override, value}` 沿出边 fan-out）
3. `lib/coconut/engines/orchid_adapter.ex` 从占位注释变成真的
   `Coconut.Engine` 实现

## 2. 生态侧的既定事实（2026-08-04 核实）

- **oi 0.7**（hex）是接入门面：DAG 拓扑 + compile-once-execute-many +
  Executor 可插拔 + `orchid_adapters` 注入管道。`OrchidInstrument` 是废弃
  实验，不碰。
- **oi 的 PortRef 就是 `{:port, node, port}` 三元组**，与 coconut 现有
  port_ref 完全同形。§11.4 的 DTO 化决议**推迟**，转换（若做）放在
  coconut↔oi 边界。
- **干预按 producer 输出端口 keying**，值包 `{:override, value}`，可整体
  短路 producer step。coconut 的 `%{port_ref => %{input: value}}` 保留为
  内核中间形状（与 equinox 同构），**不在 Resolve 层直接产 oi 格式**——
  翻译发生在 dispatch 边界，那时才知道图的边结构。
- **orchid_stratum 0.2**（hex）是内容寻址缓存层，对口增量渲染；缓存不
  自研，作为 adapter 注入（hook 顺序 oi 已管好：Intervention → Stratum →
  Core）。
- **orchid_intervention 0.2**（hex）：干预 hook 包，`:override` 语义来源。
- **kino_orchid** 目前只有 Recipe → xyflow JSON 的单向只读投影，编辑
  回路是空白。可视化远期再做；equinox 的 `GraphTranslator` behaviour
  是"UI 图 payload → 内核图"的参照契约。
- 依赖形态：**hex**（跟 equinox），不跟 tamale 的 path。

## 3. 已定决策

### 3.1 DAG 粒度：多节点粗粒度

渲染管线拆为四个阶段节点：

```
score 快照 ──> G2P ──> 音素时长 ──> Pitch ──> 声学模型 ──> (波形)
```

**前三个节点正好对应现有三路 intervention**：

| 节点 | 对应 channel | 干预效果 |
|---|---|---|
| G2P | Lyric | 改词 → 短路 G2P，直接给音素序列 |
| 音素时长 | Duration | 短路时长模型，直接给时长 |
| Pitch | Pitch | 短路 Pitch 模型，直接给音高曲线 |

声学模型消费前三者的输出，不被直接干预（v1）。

### 3.2 端口寻址：per-note port_ref → 阶段聚合端口

coconut 的 port_ref 是 per-note 的（`{:port, note_id, :pitch}`），而 DAG
节点是单个阶段 step。翻译规则（dispatch 边界的 assemble 层负责）：

- 同一阶段的干预按 note 聚合成**一个** override 值，挂到该阶段节点的
  输出端口：`{:override, %{note_id => payload}}`
- producer 节点被整体短路时，阶段内不再执行的模型计算由 override 值
  完整替代
- 此规则与 DiffSinger 现有 `collect_overrides/3` 的聚合形状
  （`note_index` keyed points）天然对齐，v1 可直接复用其转换逻辑

### 3.3 依赖

```elixir
{:oi, "~> 0.7"},
{:orchid_intervention, "~> 0.2"},
{:orchid_stratum, "~> 0.2"}
```

（orchid 本体随 oi 传递；`mix.exs:41` 的 `# add orchid or blabla` 占位注释
届时移除。）

## 4. 模块设计（coconut 侧新增）

```
Coconut.Engine.Graph        # 渲染管线 DAG 的声明（节点/端口/边的纯数据）
Coconut.Engine.Compiler     # Graph → Oi.compile，按图结构相等缓存 Compiled
Coconut.Engine.Assemble     # interventions + 图边 → oi 嵌套 data（§3.2 规则）
Coconut.Engines.OrchidAdapter  # 实现 Coconut.Engine behaviour：
                            # check = 静态校验（Recipe validate + globals 闸门）
                            # render = Oi.execute + adapters + baggage
```

> **用户**：
>
> 为啥不直接用 Oi.Graph 呢？

数据流：

```
Workspace ──Resolve.run_check──> %{port_ref => %{input}}  (内核中间形状, 不变)
        └─Snapshot.from_workspace──> Snapshot
                                    │
                Engine.Graph.declare (按引擎/声库)
                                    │
                          Compiler.compile ──> Oi.Compiled (缓存)
                                    │
                          Assemble.data ──> oi 嵌套 data + {:override, _}
                                    │
        Oi.execute(compiled, data: ..., orchid_adapters: [intervention, stratum])
```

边界原则：

- Resolve 及以下**不感知 oi**；oi 形状只出现在 Adapter/Assemble。
- 干预是**数据面**，不进可编辑的图结构；图结构节点 = 渲染管线步。
- DiffSinger worker 的 stage 拆分（G2P/时长/Pitch/声学 暴露为独立 step）
  是引擎侧工程，v1 可先用进程内 mock step 走通边界。

## 5. 阶段计划

- **Phase 0**：挂 hex 依赖；`OrchidAdapter` 变 `Coconut.Engine` 骨架
  （Mock 兜底，无 orchid 时行为不变）。
- **Phase 1**：最小端到端——toy 四节点管线（G2P/时长/Pitch/声学 均为
  mock step）走通 声明 → compile → 干预注入（验证 §3.2 聚合规则与
  producer 短路）→ execute。ExUnit 覆盖。
- **Phase 2**：DiffSinger 真实接入——worker 协议暴露 stage 边界，四节点
  换成真 step；pitch/duration/lyric 干预改经 oi override 注入；
  stratum 缓存挂上（声库/模型输出按内容寻址复用）。
- **Phase 3（远期）**：可视化。kino_orchid 补编辑回路；参照 equinox
  `GraphTranslator` 定义 coconut 的"UI 图 payload → Graph"契约。
  帧域 Metric 锚 channel（音量自动化）随 Audio 落地一并评（前文档
  :367、:374）。

## 6. 待深入讨论：intervention 的载荷设计（stub）

以下三点相互咬合，是下一版设计的核心问题，先立 stub，**未定**：

### 6.1 干预怎么挂在 Patch 上

- 现在 `Tamale.Patch.payload` 是 opaque `term()`，内核不过问形状。
- 需要拍板：每个 channel 是否声明自己的 payload schema（pitch 曲线 /
  时长表 / 歌词音素），schema 校验放在 `Patch.new/1`、channel 的
  projection，还是 check 阶段。
- payload 的版本化/迁移（工程文件序列化后，payload 形状演进怎么兼容，
  与 `Coconut.Project` 序列化联动）。

### 6.2 怎么和 Curve 结合

- `Coconut.Curve.*`（ControlPoint / Adapter / Bezier / CatmullRom）目前是
  parked 代码，零调用方（见 2026-08-04 清理记录）。
- 现在 pitch/duration 干预 payload 是稀疏折线数组（`[[tick, midi]]`），
  是否升级成 Curve container（Bezier 手柄、CatmullRom 张力）？
- 若升级：rasterize 发生在哪一层——内核（干预落地即定栅）、dispatch
  边界（assemble 时按 TempoMap 转秒域）、还是引擎/worker 内（帧域）？
  这决定 digest 比对的输入形状，也决定 §3.2 聚合端口的 override 值
  是曲线还是采样结果。
- 设计文档 :374 的旧决议"曲线模块与曲线参数的合并留待 Audio 落地"
  需要在这里一并重评。

### 6.3 怎么注入 orchid_intervention

oi 有两条干预通道，需要选型（或明确分工）：

1. **`Oi.execute` 的 `data:` 参数**：嵌套 map，`{:override, value}` 沿
   出边 fan-out，短路 producer step（equinox 走这条）。
2. **`OrchidIntervention` hook**：`baggage: %{interventions: %{io_key =>
   {:override, payload}}}`，经 `orchid_adapters` 注入，支持自定义合并
   语义（`OrchidIntervention.Operate` behaviour）。

开放问题：

- 全短路（现在的语义，producer 整步不执行）vs 部分合并（例如 pitch
  只盖住若干音符，其余仍由模型产出）——后者需要 Operate 自定义合并，
  还是由 §3.2 的聚合规则在内核侧先合成完整值再 `:override`？
- 干预值的 `Orchid.Param` 类型包装在何处补全（tuple/结构化 payload
  必须显式包 Param 才保类型，equinox 在 assemble 时包）。
- stratum 缓存键与干预的关系：被 override 短路的步其缓存自然失效，
  下游步的缓存键是否能把干预值哈希进去（`cache_keys:` 声明范围）。

## 7. 暂不做的

- port_ref DTO 化（§11.4）：推迟，边界转换即可，内核内部形状自由演进。
- fold 同 port 覆盖语义显式化：§3.2 聚合规则在 assemble 层事实上消解了
  同阶段多 patch 的覆盖问题；跨阶段同 port 不可能出现。等真出现再议。
- `run_render` 的 edit_version 强制校验：随 GenServer 壳（前文档 §11.5）。
- OrchidInstrument / orchid_symbiont：不依赖。
