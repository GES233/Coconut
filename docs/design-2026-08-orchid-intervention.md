# 设计：Intervention 层与渲染后端（Orchid/oi）接入（2026-08-04）

> 前置文档：`design-2026-07-editor-core.md`（§3 干预裁决层、§11.4 port_ref、§11.5 版本钉）。
> 本文档拍板 intervention 层的落地路径与 orchid 生态的接入方式。
>
> 2026-08-07 定位注记：项目定位更新为 "engine-agnostic editor core that
> treats user intervention as first-class"——干预层是 coconut 的主体，而非
> 渲染管线的上游配角；orchid/oi 是渲染后端的选项之一（本文 §5 Phase 0–2
> 尚未开始）。§1"缺的半层"叙事以 equinox Runner 为参照系、写于旧定位下，
> 存档保留；§4 边界原则（Resolve 及以下不感知 oi）与新定位一致，不变。
>
> 2026-08-09 归属注记：Orchid 接入（Adapter/Assemble + oi 三件套依赖）
> 独立成包，不进 coconut 树——coconut 只保留 `Coconut.Render.Engine`
> 契约面，与 application-less、OTP 归下游同一条宪法；树内占位文件
> `engines/orchid_adapter.ex` 已删。§3.3/§4/§5 Phase 0 已按此改写。

## 1. 背景与现状

coconut 的干预链路已落地到 equinox 集成路径的中段：

- `Coconut.Edit.Patch`（anchor + tamale patch + channel）→ `Workspace` 写时 transport
- `Coconut.Render.Resolve.run_check/3`：channel spec 投影 → digest 零容差比对 →
  `fold_resolved` 产出 `%{port_ref => %{input: value}}`
- 三路 channel 已接 DiffSinger：Lyric / Pitch / Duration
  （`lib/coconut/engines/channels/`）

**缺的半层**（对照 equinox `Runner` 的 Compiler + assemble_data）：

1. 渲染管线的 DAG 声明与编译（`Oi.compile`，按图结构缓存）
2. interventions → oi 嵌套 `data:` 的翻译（`{:override, value}` 沿出边 fan-out）
3. `OrchidAdapter` 从占位变成真的 `Coconut.Render.Engine` 实现
   （2026-08-09：树内占位文件已删，实现归独立 adapter 包，见 §3.3/§4）

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

### 3.3 依赖与归属（2026-08-09 改写）

Orchid 接入**独立成包**（工作名 `coconut_oi`，建包时定；sibling mix 项目 +
path dep 起步，不急发 hex），三件套挂在该包：

```elixir
{:coconut, path: "../coconut"},
{:oi, "~> 0.7"},
{:orchid_intervention, "~> 0.2"},
{:orchid_stratum, "~> 0.2"}
```

（orchid 本体随 oi 传递。）coconut 本体**不新增任何 oi/orchid 依赖与
模块**，只保留 `Coconut.Render.Engine` behaviour + `Request`/`Snapshot`/
`Resolve` 契约面——engine-agnostic 定位与 application-less 决议的直接
推论；树内占位文件与 `mix.exs` 的 `# add orchid` 注释已删。契约漂移
纪律：Engine 契约面 breaking 时 adapter 包同步跟进，path dep 阶段无感。

## 4. 模块设计（adapter 包新增）

> 2026-08-06 更新：按 2026-08-05 决议落实为 **thin wrap**——不建 Graph DSL /
> Compiler：渲染管线 DAG 直接用 `Oi.Graph` 声明（节点/端口/边是 oi 的纯数据，
> 图结构相等缓存 `Oi.compile` 自带）；coconut 只补 per-note → per-node 的
> 聚合翻译（§3.2 规则），无需 DSL 层。原拟 `Coconut.Engine.Graph` /
> `Compiler` 废弃；`GraphTranslator` 的 UI 图翻译参照（equinox）属可视化
> Phase 3 的事。
>
> 2026-08-09 归属更新：本节两个模块归独立 adapter 包（§3.3），coconut
> 树内不再新增任何 oi 相关模块；模块命名空间建包时定（下文沿用
> `OrchidAdapter` 工作名）。边界原则随之升级为包缝——"oi 形状只出现在
> Adapter/Assemble" 由依赖图强制，不再仅靠约定。

```
Coconut.Engines.OrchidAdapter      # 实现 Coconut.Render.Engine behaviour：
                               # check = 静态校验（Recipe validate + globals 闸门）
                               # render = Oi.execute + adapters + baggage
Coconut.Engines.OrchidAdapter.Assemble  # interventions + 图边 → oi 嵌套 data（§3.2 规则）
```

数据流：

```
Workspace ──Resolve.run_check──> %{port_ref => %{input}}  (内核中间形状, 不变)
        └─Snapshot.from_workspace──> Snapshot
                                    │
            Oi.Graph 声明（按引擎/声库）──Oi.compile──> Oi.Compiled (缓存)
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

- **Phase 0**：立 adapter 包骨架（sibling mix 项目 + path dep），挂 hex
  依赖；`OrchidAdapter` 变 `Coconut.Render.Engine` 骨架。Mock step 归该包
  测试设施——coconut 无"无 orchid 时"运行时分支，没装 adapter 包即无
  orchid 引擎。
- **Phase 1**：最小端到端——toy 四节点管线（G2P/时长/Pitch/声学 均为
  mock step）走通 声明 → compile → 干预注入（验证 §3.2 聚合规则与
  producer 短路）→ execute。ExUnit 覆盖。
- **Phase 2**：DiffSinger 真实接入——worker 协议暴露 stage 边界，四节点
  换成真 step；pitch/duration/lyric 干预改经 oi override 注入；stage
  输出对 extract 开放读取（§6.3）；stratum 缓存挂上（声库/模型输出
  按内容寻址复用）。
- **Phase 3（远期）**：可视化。kino_orchid 补编辑回路；参照 equinox
  `GraphTranslator` 定义 coconut 的"UI 图 payload → Graph"契约。
  帧域 Metric 锚 channel（音量自动化）随 Audio 落地一并评（前文档
  §11.8）。

## 6. Intervention 载荷设计（2026-08-07 拍板）

> 本节由原 stub（2026-08-04）填实：载荷分类学（§6.1）、多音符身份（§6.2）、
> 参数曲线工作流（§6.3）、精确化 spec（§6.4）已定；oi 注入选型（§6.5）
> 仍开放，随 Phase 1/2 定。

### 6.1 payload 分类学：三种形状（已定）

干预按载荷形状分三类；channel 声明自己属于哪类并携带对应 schema：

| 类 | 锚 | payload 形状 | 现存 channel |
|---|---|---|---|
| 身份（identity） | Ordinal（单音，或 §6.2 的多音 group） | 离散内容序列（音素对 `[[lang, ph]]` 等） | Lyric |
| 时值（timing） | Ordinal / Relative | 稀疏钉 `[[ph_index, dur_tick]]` + phoneme→note 对齐 + pre-utterance | Duration |
| 参数曲线（curve） | Ordinal / Metric 区段 | 控制点容器（§6.3、§6.4） | Pitch（现为稀疏折线 `[[tick, midi]]`，待升级为控制点容器） |

拍板：

- `Tamale.Patch.payload` 保持 opaque `term()`，内核不过问形状（不变）。
- **schema 校验点 = 挂载/lower 边界**：channel 提供 cast（适配层义务），
  不进 `Patch.new/1`（内核只查锚的 coord 合法性）；check 阶段的投影产
  canonical form 供 digest。
- **版本化/迁移归 channel**：payload 形状演进由 owning channel 负责；
  `Pickle.Patch` 原样存 term，老档加载时 channel cast 失败 = loud error
  （pickle 惯例），不做静默迁移。
- timing 类显式包含两个维度（2026-08-07 补入）：**phoneme→note 对齐**
  （音素归属哪个音符 / group 成员，melisma 下与 §6.2 同一份数据）与
  **pre-utterance**——锚定用 `Anchor.Relative` 负偏移（tamale 原生允许
  越界 overhang，无宿主内不变式），投影与消费按引擎语义处理。

### 6.2 多音符抽象身份：syllable group（已定，frame–content）

动机：melisma（一个音节跨多音）的音素序列属于音节而非单个音符，
per-note 锚无法表达"这组音符共同承载一份内容"。这是 Frame/Content
结构——frame（音节框架 = 跨音符的身份）+ content（音素序列），也为
基于 Frame/Content 的引擎设计预留接口形状。

拍板：**不引入新锚类型**，复用 tamale 既有机制：

- **frame 身份 = `Anchor.Ordinal{refs: [note_id, ...], adjacent?: true}`**：
  conjunctive refs（丢任一成员即死）+ adjacency（成员须保持顺序相邻，
  断裂即 `{:undefined, :adjacency_broken}`）。Move 同批存活；成员
  Delete/Merge 杀锚；成员 Split 破坏 adjacency（新 id 插入 refs 之间）
  锚死——v1 取此保守语义（同 tempo_ramps"简单狠"先例：被打散的
  melisma 其音节级干预失效，重开编辑器时按现状重推成员）；放宽
  （split 后成员自动扩列）留作策略层后话。
- **content = payload 的音素序列 + 成员对齐**（即 §6.1 timing 类的
  phoneme→note 对齐）。
- group 的编辑侧记录（成员有序表、音节元数据）走内容级侧表，不落
  op——与"歌词/控制点不落 op"先例同构；group 级 projection（成员 id
  有序表 + 各成员 canonical）由 channel 实现，作为 digest 的 base。

### 6.3 参数曲线：extract → edit → land（已定）

1. **extract**：Base = 引擎 stage 输出投影（如 pitch predict 的 f0）。
   渲染 DAG 因此须暴露 stage 输出**用于读取**，不只是 override 的短路
   点——§5 Phase 2 的 worker stage 拆分范围随之包含"可抽出"。extract
   是异步引擎往返，GenServer 壳的 job/事件模型按"编辑 + extract 两类
   往返"设计。
2. **edit**：payload = 控制点容器（Bezier 手柄 / CatmullRom 张力为适配层
   参数化），坐标按 §6.4 spec 精确化。**rasterize 发生在消费边界**
   （dispatch/engine，经 TempoMap 转秒/帧域），不进内核、不进
   digest——digest 的输入是控制点 canonical form。与 tempo-curve
   "Step 为骨、曲线为皮"同构：内核只见精确值，连续曲线是编辑投影。
3. **land**：`base_digest` 钉在 extract 时刻的 Base 投影上。**Base 漂移
   语义（显式化）**：模型/声库更换或上游编辑使 Base 变化 → digest 失配
   → conflict，干预否决、交由用户确认重录。这是预期行为而非故障：
   干预钉死在它诞生时的底料上。

对 `Coconut.Curve.*` 的处置（07 文档 §11.8"曲线模块与曲线参数的合并
留待 Audio 落地"旧决议由此了断）：parked 代码收编为**适配层曲线参数化
库**——Bezier / CatmullRom 作控制点容器的插值模式；当前实现是 float
世界（`tension: 0.5` 等），完成 §6.4 exact 化之前只用于编辑投影与
rasterize，不出现于 canonical form。

### 6.4 精确化 spec：canonical payload 整数化规范（已定）

凡进入 digest 的 payload 与其 canonical 投影必须满足（`Tamale.Digest`
拒 float / 拒 struct 的直接推论）：

1. **时间**：tick / frame 一律整数；秒只以整数微秒出现在导出/展示边界
   （前文档 §4 既有约定延伸至 payload）。
2. **值**：尽量整数化，量化单位由 channel 声明——bpm → milli-bpm（既有
   先例）；音高偏移 → 整数 cents / milli-cents；无法整数化的用
   `{num, den}` 有理数。float 与 struct 一律禁止。
3. **音高**：canonical 形状由 Key 模块拥有——TwelveET 为 `%{midi: n}`
   （音符）/ 整数 cents 偏移（曲线点）。Key 可插拔的设计动机即将来
   引入民族调式 / 微分音：新 Key 模块定义自己的精确 canonical，内核
   与本 spec 不预设 midi。改任一 canonical 形状 = breaking change
   （全部已挂 patch 的 base_digest 失效，前文档 §11.7 既有）。
4. **schema 版本**：channel 声明 payload schema 版本；落盘随
   `Pickle.Patch` 原样存取，加载由 channel 校验/迁移（§6.1）。

### 6.5 怎么注入 orchid_intervention（仍开放，随 Phase 1/2 定）

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
