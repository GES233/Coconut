# Coconut 设计草案：引擎无关编辑器内核（Intervention First-class）

> 2026-07-29 调研讨论存档。来源：对 Qy 下 tamale / oi / equinox / zongzi /
> zongzi_feasibility 五个项目的调研结论与架构决策。
>
> 模块命名（2026-08-06 起）：`edit/`、`render/` 下的实现统一加
> `Coconut.Edit.` / `Coconut.Render.` 前缀（`Operate` → `Edit.Operation`、
> `Operations.*` → `Edit.Operations.*`，余类推）；存档段落保留当时定名，
> 裸词 Workspace/Track/Resolve/Engine 为架构概念名。

## 1. 定位与选型

coconut 是一个**引擎无关（engine-agnostic）的编辑器内核，将用户干预
（intervention）视为一等公民**。SVS 是首发应用域而非定义。干预——Patch
挂载、写时 transport、digest 零容差比对、两段式否决——是内核的主轴，
渲染引擎只是其下游消费者之一。它不是重写这些库：

- **干预机制 = tamale**（`Qy/tamale`）：Space / Op / Anchor / Transport / Patch，
  零依赖纯函数内核，三方合并模型，测试 + JSON 一致性向量齐全。
- **调度引擎 = orchid/oi**（`Qy/Orchid` + `Qy/oi`）：已固化，维护者即本人；
  未来变化只会以新 Executor/Hook 形式出现。直接作为稳定平台依赖，不重写。
- **集成参照 = equinox**（`Qy/equinox`）：domain + kernel 两层（去掉 ui_shell）
  即 headless editor 的骨架；Runner 的"两段式 check + 装配 + Blackboard 增量
  缓存"架构照搬，其中 zongzi Declaration 部分换成 tamale。
- zongzi / zongzi_feasibility 不再直接使用；后者的 Scenario 模式已移植为
  coconut 的验收测试（最小集，Measurer 报告台不搬，见 §10）。

## 2. 总体架构

```
接口层（Elixir API / JSON-RPC stdio / CLI / MCP，可扩展）
  → command 翻译 + dispatch（按 workspace_id 路由）
  → Workspace（聚合根，单写者，命令全序点；当前纯模块，GenServer 壳挪 v2，§10）
      tracks: %{track_id => Track.t()}    # 音符轨
      globals: %{global_id => Track.t()}  # 全局轨（内建 tempo 等），id 带 "global:" 前缀
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
（音符 / tempo 事件 / clip）**。不使用 "Timeline" 一词（避免与 zongzi 旧机制串味）。

## 3. 干预裁决层（`Coconut.Render.Resolve`）

tamale 的干预模型与引擎/调度器范式不同，Resolve 显式隔离两者——它是干预
链路的裁决层，而非某个渲染后端的适配器。职责只三条：

1. tamale transport/resolve 结果 → 折叠为引擎无关的中间形状
   `%{port_ref => %{input: value}}`（存活干预转 `:override`、按 producer
   端口 keying 的 oi data 翻译发生在 dispatch 边界，见
   design-2026-08-orchid-intervention.md §2/§4）；
2. conflict（含 clip / ambiguous）全量聚合为一票否决（verdict
   `%{passed: false, entries}`；equinox Runner 语义照搬）；
3. 反向：用户编辑手势 → tamale Op 脚本。

配套契约：

- **channel** = `Coconut.Render.Channel` behaviour，注册表即 `run_check/3`
  的 channels map（值为 behaviour 模块）；首发三路
  见 §9。不挂音符的全局参数走 `Request.globals`：过 check（`Engine.info`
  的 `:globals` 声明做白名单+范围/枚举校验）、不过 resolve（无
  anchor/digest/transport），render 透传。
- **两段式交接**：`Engine.check/2` 的 checked 由 `render/3` 消费而不重算
  （DiffSinger 的 dur/pitch 前向即经此复用）。两层 check（Resolve 与
  Engine）统一 verdict 语义：`{:ok, %{passed: ...}}` = 检查执行完毕
  （false 即否决，entries 为全量明细），`{:error, _}` 只留给检查自身
  无法执行（worker 崩溃、配置缺失、输入无法装配）。
- **Encoder 契约** `Coconut.Render.Encoder`（note→request token，形状对
  契约不透明、由引擎定义）：phrase 粒度、逐轨调用、现算；v1 手动配置，
  声库自动推导留待声库声明层。
- **元素数据流**：lowering 把音符 attrs 铸成 `Coconut.Score.Note`
  （pitch → `Key.TwelveET`，其余进 metadata），`elements_by_id` 直接存
  struct；tempo 事件等非音符元素仍存裸 map。digest 场景走
  `Note.to_canonical/1`（key 经 `Map.from_struct` 归约为 `%{midi: n}`，
  Tamale.Digest 拒 struct）。

参照：equinox `Runner.resolve_units` / `fold_resolved`。

## 4. 时间基准（硬约定）

- **tick = 结构层权威坐标**：音符、干预锚都挂 tick（Metric 或 Ordinal）。
- **帧/采样点 = 引擎层坐标**：digest 投影与渲染窗口使用，整数帧号。
- **秒只允许以整数微秒出现在导出/展示边界**。float 在所有内核边界被拒绝
  （tamale Coord 学说），归一化在适配层完成，舍入只发生在最终消费点。
- **tempo 结构层只支持阶梯（step），不支持线性 ramp**——Warp 段是有理数端点的
  线性段，ramp 的二次曲线无法精确表达，会破坏 digest 零容忍比对。
  渐速靠加密 tempo 点逼近，采样端拟合。渐速编辑的落地路径见
  `design-2026-08-tempo-curve.md`（Step 为骨、曲线为皮、bake 为界——
  曲线是适配层编辑投影，经确定性 bake 落到阶梯事件；本约定不变）。
  线性插值留给消费层在出现真实接线需求后实现：tempo 轨只产 Step
  事件，op / digest / warp 只见阶梯（见 tempo-curve 文档 §2）。
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

1. **坐标支持（2026-08-11 更新）**：`:tick` 与 `:frame` 原生 builder 都在
   dispatch 表内——`:frame` 条目共用同一套非 ripple 构造（audio 轨的
   span 本就是帧坐标，无需 tempo 知识），audio 轨的帧域 Metric 锚随之
   解锁；帧域 Metric 锚也可挂 tick 轨（跟谱、帧寻址，需工程声明
   `frame_rate`，见第 4 条）。tick warp 与
   tempo 无关（tempo 变化 tick 不动），provider 是纯函数：
   `ops + span 快照 → Warp`。
2. 维护**版本化 span 表** `%{version => %{id => span}}`（不可变 map 结构共享，
   每版一份近零成本；随 Space.truncate 同步裁剪）。不需要 Tick↔Sample 表
   ——TempoMap 本身就是那张换算表，现算即可。
3. **ripple 策略藏在 provider 里**：v1 走非 ripple（钢琴卷语义，拉伸音符不
   推动后续）。要 ripple 时在段表后追加平移段即可，内核与 op 不变。
4. 帧空间 warp（v2）：`W_frame = T_new ∘ W_tick ∘ T_old⁻¹`，用
   `Warp.compose/invert` 组合。验收用 tamale 一致性向量 metric 族
   （G-INT-03/05 场景）。**自动化拆两级**（2026-08-09 拍板）：clip 级
   （automation 跟 clip 走）用 Ordinal 锚 + clip 相对帧偏移 payload，
   恒等 transport、零 warp，先行落地；轨级（跨 clip、钉时间线）才需要
   帧域 Metric 锚与本条 warp，排晚期。**已完整落地（2026-08-11）**：
   - 语义拍板：tick 轨上的帧域 Metric 锚 = **跟谱、帧寻址**——from/to
     是引擎帧号，但跟随乐理编辑（本轨 Retime 经对组合映射），纯 tempo
     编辑也要移动它（否则锚静默指错音符，正是对组合的存在意义）；
     audio 轨（帧域轨）不动（§4 硬约定）。
   - 跨轨版本关联设施：每轨 `version_clock`（space version →
     edit_version，apply_batch 记录、truncate 同步裁剪、Pickle 可选
     字段入档）；`Workspace.tempo_steps_at/2` 经 tempo 轨 clock 反查
     版本后取精确阶梯事件（`Track.Tempo.tempo_steps_at/2`，整数
     milli-bpm——tamale `Coord` 拒 float，`TempoMap` 的秒是 float
     设施，T 只能从精确事件构造，与 tempo-curve 文档
     "线性 tempo 插值永不进 warp"同一约束）。
   - 接线：`frame_over_tick/3`（context `%{tempo_pair_at, frame_rate,
     tpqn}`，tempo_pair_at 返回 `{T_old 事件, T_new 事件}`）经
     `for_coord/4` 进 dispatch——tick 域闭包同时服务 :tick（原生）与
     :frame（对组合）；挂载守卫放开 coord == domain 或（:frame 锚上
     tick 轨且已声明 `frame_rate`，否则 `{:error, :missing_frame_rate}`）。
   - **echo transport**：tempo 批次不产生其他轨的 log 条目，故
     apply_batches 触及 tempo 轨后追加一轮 echo——所有未触及的 tick
     域轨上的帧锚经 `WarpProvider.tempo_shift/5`（`T_new ∘ T_old⁻¹`）
     移动；判死进坟场（可见）。同一手势触及的轨跳过（其写时
     transport 已用 entry 的 T 对，echo 会二次移动）。
   - 已知限制：bpm 改值是内容编辑（不落 op、不入版本），历史 T 用
     当前 bpm 值近似——fold 区间内改过 bpm 时帧锚按新值结算；
     tempo 事件的增/删/移是 op，对组合精确。
5. provider 分派：构造点（写时 `Workspace` / 检查时 `Resolve`）经
   `WarpProvider.for_coord/4` 按轨的 `coord_domain/0` 查分派表构造
   closure，`supported_coords/0` 从同一张表推导（`Patch.new` 挂载守卫
   随之自动放开）；无 builder 的 coord 返回 nil，走 `transport_patches`
   既有 nil 语义（Ordinal 恒等 transport，Metric 以
   `:warp_provider_required` 判死而非 clause 缺失崩溃）。第 4 参数
   context（`WarpProvider.frame_context()`）由
   `Workspace.warp_context/2` 统一构造：tick 域闭包在其存在时额外服务
   `:frame`（T 对组合），缺席时 `:frame` 调用可见失败而非崩溃。锚
   coord 与轨 domain 的一致性由 `attach_patch` 把关：
   Metric coord ≠ 轨 coord_domain 拒（`{:anchor_coord_mismatch, _, _}`），
   唯一例外是帧域锚上 tick 轨（第 4 条，需 `frame_rate`）。

## 6. Tempo Track = 一条独立 Space

tempo 变化作用于工程所有轨道 → tempo 是工程级数据：

- tempo 事件作为元素住自己的 Space（id + tick span + 侧表存 bpm）；
- bpm 以 milli-bpm 整数存储（有理数）；请求侧收普通 bpm 数值，由
  `Tempo.cast_bpm/1` 在 lower 时归一化（float 只在此一处舍入）；
- tempo 编辑自动落 op log（Insert/Delete/Retime），为帧 warp 提供原料；
- 平铺约定：宽松——洞由阶梯语义自然继承前一元素 bpm（TempoMap 段持续
  至下一事件），首元素受保护不可删除（`Track.Tempo.validate_gesture/3`）；
- `:tick` provider 对 tempo log 永远返回 identity；tempo Space 自身几乎
  不会被挂锚，其角色是"序列化容器 + log 发生器"；
- tempo 轨的存放：Workspace `globals` map 的内建全局轨，id 为
  `"global:tempo"`（全局轨只用 id 寻址，`"global:"` 前缀即路由规则，
  与普通轨命名空间结构性隔离）；绑定按能力不按模块身份：任何导出
  `tempo_events/1` 的 track module 都可占据 tempo 槽位（投影知识在
  模块上，`Workspace.validate/1` 把关能力与命名空间）；
  `fetch_track/2`/`apply_batch/5` 等按 track id 前缀路由到 `globals`；
  tempo 槽位缺失或空轨（无事件）时 `Workspace.tempo_map/1` 报
  `:missing_tempo_track`，引擎走自有回退；
- 拍号（TimeSig）：**不作 track**，落 `Workspace` 的 `time_sigs` 字段
  （`[{bar, sig}]` 事件列表，支持中途变拍；bar 是权威坐标，首事件须在
  bar 1 且小节序号严格递增，`Workspace.validate/1` 把关）。它是 tick
  之上的显示/网格叠层（小节标尺、吸附），不移动 tick、无锚、无
  transport，进 Space 是纯开销；`TimeSigMap` 读时编译
  （`Workspace.time_sig_map/1`，按 `ws.tpqn`）。散拍子 `:san` 暂不考虑。
  但变拍是乐谱手势、须可撤销：`time_sigs` 的写入口是
  `Workspace.set_time_sigs/2`（`update/2` 拒收），入史为
  `set_time_sigs` 命令边（§12.4），边存全量新值。`tpqn`
  仍随 `update/2`，不入史。

## 7. Op 覆盖评估

六 op（Insert/Delete/Split/Merge/Move/Retime）覆盖"顺序、身份、时间"三个
正交轴，音符序列 + 曲线参数的编辑需求为最小闭集：

- 纯内容编辑（歌词/音素/曲线控制点）**不落 op**，只写侧表，走 Patch/digest
  语义轴；
- 撤销/重做 = Op 树 + 检查点（§12）；
- 跨轨拖动 = 源 Space Delete + 目标 Space Insert，锚判死由策略层重挂
  （"Relocation is policy, not transport"；死 patch 在各轨的
  `track.dead_patches` 等策略层经 `Workspace.take_dead_patches/1` 收取）；
- 跨 Space 原子性由 Workspace 串行化 + 校验前置保证；
- 非单调碰撞（扩张/右移压过邻域）的 Metric 锚按旧域序水位线裁决：先到
  先得像，后续 identity 截断、冲突段成洞，受影响锚死于 transport
  （warp_provider 场景测试已钉死）；
- 同轨复音（重叠音符）不支持；协作/离线分支不支持（单写者线性 log）。

## 8. 已知缺口（coconut 侧待补）

已补齐：warp provider（§5）、undo（§12）、diff 适配器（见首条）。
待施工的两件（跨 Space 重挂方案已拍板，见末条）：

- **diff(old, new) 回退适配器**：已落地（2026-08-11，`Coconut.Edit.Diff`，
  与 `Operation` 同级）。正常路径是手势 → op 批次；文件导入
  （MIDI/UST）、外部整轨改写、整块粘贴只给"改完的状态"，由它在旧轨
  快照与新元素列表间反推六 op 序列，输出标准 `ops + side_changes`
  走同一 `apply_batch` 管道，不确定性收口在这一个函数。两个原未拍板
  点已定：①身份匹配**分层**——先复合键（span + 去 id 的元素内容）
  精确配对，再按 span 重叠度**互为严格最优**贪心兜底（重叠相同则
  start 近者胜；任一方向平分即放弃）；②保守策略**宁可 Delete +
  Insert 不错认**——错认 Retime/Move 会让 patch 载荷静默挂错对象，
  Delete+Insert 则 id 换新、patch 判死进坟场（可见失败，策略层可
  重挂）。配对成功的 span 变 → Retime、内容变 → 侧表 upsert（纯内容
  编辑不落 op，§7）、序列变 → Move。新元素经轨型模块 `cast_element/3`
  重铸（内容合法性在此把关）；新状态的轨型政策合法性（如 Vocal 不
  重叠）是调用方责任——diff 走 apply_batch 本就绕过 validate 层。
  骨架通用、Vocal 先行（Tempo/Audio 的匹配键随用到再定型）；头号
  用户 MIDI 导入在下游排期。
- **chunked digest helper**：`Tamale.Digest.digest/1` 一次性吃完整
  canonical term，整轨投影大时物化成本高；helper 为分块流式 digest。
  命门：分块结果必须与一次性 digest **逐比特一致**，否则同一内容的
  `base_digest` 因调用路径分裂、patch 存活判定崩——故方案围着
  canonical 编码可分段拼接这个不变量设计，不是简单包 `:crypto` 的
  init/update/final。用途排序：channel digest 投影 > voicebank digest
  实算（v1 只存不算）> 工程级 digest。落点 tamale 侧为主。等投影规模
  真的疼了再做。
- **跨 Space 重挂（跨轨拖动）**：已落地（2026-08-10，选项 a）——
  新 id + patch 不迁移（id 是 Space 级身份：沿用同 id 则 A 轨钉着
  它的 patch 全 terminal；换新 id 则原锚全判死）。手势 =
  `Operations.DragNoteAcrossTracks`：A 轨 Delete + B 轨 Insert 的
  双轨批次（可选回调 `Operation.lower_batches/3` 产出），经多轨
  原子入口 `Workspace.apply_batches/3` 提交（单 version 检查 +
  两条 log + 单次 `edit_version` bump），**记一条 History 边**
  （§12.4——否则一次拖动两步 undo）。目标轨元素载荷由请求的
  `attrs` 显式给出（目标 module 的 `cast_element/3` 把关，允许跨
  轨型拖动）。判死 patch 的恢复：坟场为主（payload 完整，策略层
  重挂/手动恢复），History 漫游兜底（`state_at` 复制粘贴；squash 后
  远古状态不可达，兜底有边界）。选项 b（同 id 打捞）/ c（patch 迁移
  表）留作后期 refinement。tamale 不动。

## 9. 首发形态（前置条件，已定）

1. **引擎面**：首发 DiffSinger（OpenUTAU 格式声库），经
   `Coconut.Engines.DiffSinger` + `engines/diffsinger/worker.py`
   （NDJSON stdio）接入；UTAU classic 备选。engine-agnostic 定位下引擎面
   边界由 Engine / Channel / Encoder 三契约定义，DiffSinger 是契约的首个
   参考实现而非引擎面本身。
   > **注记（2026-08-09）**：DiffSinger 引擎全家已迁出至 sibling 包
   > `coconut_diffsinger`（命名空间 `CoconutDiffsinger.*`，含
   > worker.py / PortClient / Encoder / Encoders.Literal）；本仓
   > Engines 命名空间只剩 reference/test 引擎 Mock。
2. **坐标基准**：tick 权威 + 帧 + 微秒（§4）。
3. **首发 channel**：音素 / 音素时长 / 音高三路
   （`Render.Channels.Lyric` / `Duration` / `Pitch`，对齐 DiffSinger 的
   tokens/durations/f0 三路模型输入），每 channel 一个 adapter：
   warp_payload + digest 投影，是工作量乘数。
4. **API 边界**：Elixir API + JSON-RPC/stdio + CLI 三件套，MCP 后加；
   渲染为长任务（check 同步一票否决，render 异步 job + 事件）。随
   GenServer 壳施工（§10）。
5. **持久化**：Pickle codec（`lib/coconut/pickle*.ex`）；Project 只保留
   已定形的 workspace / voicebank / metadata，未来字段不进入领域模型；
   codec 兼容旧档中为 nil 的 engine/settings/assets。文件外壳为
   `%{format, version, project}` 信封 + `term_to_binary`。

## 10. 状态与 v2 排期

v1 已收官：Workspace 纯函数内核（lowering + 写时 transport + 坟场）、
warp provider、Tempo Track、Resolve + Engine 两段式 + channel 注册表 +
globals 闸门、DiffSinger 接入（pitch/dur override 全链路、Encoder +
Literal + dsdict 编码）、Snapshot/Artifact、Pickle、History（§12）、
Track.Audio（§11.8）。验收测试 = zongzi_feasibility Scenario 模式移植的
最小集（G-INT-01/02，`test/support/scenarios/`，G-INT-01 按 coconut
语义重写：patch 存活左半、右半天然无 patch 为验收点；Measurer 报告台
不搬——coconut 的投影是 channel digest 切片，无图可画）。场景家族
暂停扩：编辑回路已成型、机制面由常规 ExUnit 覆盖；难场景（G-PRE 族、
相对曲线）需引擎投影级 snapshot，等真实投影/曲线落地后直接对 coconut
语义写新验收。

v2 遗留：

- GenServer 壳 + 接口层（JSON-RPC/stdio 优先）——v2 差不多时一口气收尾；
- 帧空间锚 + tempo 对组合（§5 第 4 条）——已落地（2026-08-11）：
  跨轨版本关联（per-track `version_clock`）、真 `T_old`/`T_new` 对组合、
  dispatch/守卫接线（帧域锚上 tick 轨，需 `frame_rate`）、tempo echo
  transport；已知限制见 §5 第 4 条；
- orchid/oi 接入——adapter 独立成包，见 design-2026-08-orchid-intervention.md
  §3.3/§4 与 Phase 计划；
- diff 适配器——已落地（2026-08-11，`Coconut.Edit.Diff`，决策见 §8）；
  头号用户 MIDI 导入在下游排期（跨轨拖动已于 2026-08-10 落地，§8）。

## 11. 已知架构问题与演进方向

以下为评审确认的存量问题及其结论；未标注「已定」的方向均未拍板，改动前
需先在这里更新结论。

### 11.1 Snapshot / Request / Artifact（已定）

引擎不见 Workspace：`Snapshot.from_workspace/1` 拍扁各轨 view
（`Track.view/1`）+ 编好 `TempoMap` + 钉 `edit_version`；`Request` 携带
Snapshot（`for_workspace/2` 构造）；`Artifact{engine, edit_version,
payload, globals, overrides}` 为渲染产物形状。原有三份"拍扁乐谱"
（DiffSinger/Mock/Workspace 各一份）收敛为 `Track.view/1`——引擎不该
知道 `spans_by_version`、`elements_by_id` 长什么样，侧表结构一变所有
引擎跟着碎。

### 11.2 Note 不存 tick（已定，方案 a）

Note 只做内容载体（key/lyric/metadata），时间一律走 spans 表。原问题是
时间双真相：`Note.start_tick` 是插入时快照，spans 表才是权威，两处都
"像真的"，读错一处就是静默错位；核实后 tick 字段事实上 write-only
（lib 内无任何引擎读它），遂删除。`Note.split/5`/`merge/6` 一并退役——
lowering 走 span 几何 + `split_elements/2`，从不经过 Note；内容（lyric
等）合并策略留给调用方（`Coconut.Edit.Operations.EditNote`）。

### 11.3 Track 侧表与 truncate（已定）

旧 `Side` struct（spans/elements/patches/dead_patches 杂物抽屉）已整个
删除，字段随 `Coconut.Edit.Track` 下沉。`spans_by_version` 的无界增长由
`Track.truncate/2` + `Workspace.truncate/3` 收口：随 `Space.truncate`
同步裁剪，span 快照保留 cut 处最新一份作 baseline（warp 的
`spans_at(v-1)` 需要它）。`version_clock`（§5 第 4 条的跨轨关联设施）
随同一 truncate 裁剪，同样保留 baseline。

### 11.4 port_ref 语义（DTO 化推迟；现状 `{:port, node, port}`）

oi 的 PortRef 与本项目 port_ref 同形，DTO 化决议无限期推迟，转换（若做）
放在 coconut↔oi 边界；fold 同 port 覆盖问题经 orchid-intervention 文档
§3.2 的聚合规则在 assemble 层事实上消解，等真出现再议。若重做，方向：
显式 DTO（字段命名语义，如 `%{scope, kind, id}`，不用位置元组）+ fold
覆盖语义显式化 + 端口注册/声明处（多引擎并存前）。

### 11.5 check → render 的版本钉（钉已落地，强制校验随壳）

`Request` 是值快照，checked 之后 workspace 变了须能发现：`Snapshot` 钉
`edit_version`（`Request.for_workspace/2` 构造即钉；`Artifact.edit_version`
记录渲染来源版本）。钉的完整形状随 §12.2：History 签发的 cursor node
id——`Snapshot` 加可选 `pin` 字段，壳经 `History.current/1` 构造
Request 时填入；裸构造路径（lib 内部与测试）留空、只钉
`edit_version`。强制校验（壳比对 client 钉 == cursor node id）随
GenServer 壳。

### 11.6 PortClient 无监督 + key 切换队列污染

> **注记（2026-08-09）**：PortClient 已随 DiffSinger 全家迁出至
> `coconut_diffsinger` 包（`CoconutDiffsinger.PortClient`）；本节问题
> 随之移交该包，修复在冻结约束（只修 bug）下进行。

**现象**：全局单例 GenServer 不在 supervision tree 下；worker key 变化时
旧 key 的排队请求会落到新 worker（v1 注释妥协）。

**方向**：挂监督树；key 切换时 fail 掉旧队列而非误投（多声部/多声库时
重做）。

### 11.7 毛边（记入 backlog，随用随修）

- 错误词汇（已定，2026-08-11）：内部 reason 三家语义——`invalid_x`（值
  形状非法）/ `unknown_x`（引用悬空）/ `missing_x`（必需物缺席，原
  `no_*` 并入）；lib 内部全链路裸 reason。`Coconut.Error`
  （`defexception`，字段 `reason`，`wrap/1` / `unwrap/1`）定位为壳/
  接口层的边界工具：lib 内任何模块不调用它，wrap 发生在壳/JSON-RPC
  对外序列化前（或 sibling 包自己的边界）。曾在四个聚合根模块的公共
  API 处试 wrap，但这些函数同是库内苦力（`fetch_track` / `tempo_map` /
  `apply_batches` 等被 Operations、Render、Pickle 广泛调用），每个内部
  消费点被迫 unwrap、dialyzer 连锁误报 22 处——边界类型出现在调用图
  中段是错误切法，当日即外移。
- `Note.to_canonical` 的 key 形状（`%{midi: n}`）是隐性契约：换 tuning
  或改形状 = 全部已挂 patch 的 base_digest 失效。改 canonical 形状视为
  breaking change。
- `Workspace.tempo_map/1` 每次现编 TempoMap；大工程下考虑缓存。
- ~~`Engine.Snapshot.from_workspace/1` 的 `tracks` 只含 `ws.tracks`~~
  （已补，2026-08-11）：`tracks` 改走 `Workspace.all_tracks/1`，tempo 轨
  以 `"global:tempo"` 携带原始事件 view（`Track.Tempo.view/1`），引擎
  不再只有编译后的 `tempo_map`——tempo ramp 干预、tempo 编辑的 patch
  投影的共同前置已解锁。

### 11.8 Track 抽象

`Coconut.Edit.Track`（struct + behaviour）吸收轨型特判：Track 拥有一切
曾属于 workspace 侧表抽屉的东西——版本化 span 表（timing 权威，§11.2）、
元素载荷、per-track patches（干预按轨 transport、按轨存放）。

- `%Track{id, name, metadata, extras, module, space, spans_by_version,
  version_clock, elements_by_id, patches, dead_patches}`；`metadata` 是展示注释，
  `extras` 是宿主命名空间下的工程扩展事实；两者默认 `%{}`，只允许
  `Coconut.Pickle.pickle_conform?/1` 的 plain 数据，不能承载运行时对象。
  Workspace =
  `id/edit_version/tracks/globals` + 工程级 `tpqn/frame_rate/time_sigs`
  （§6）。`frame_rate` 是引擎帧网格声明（正整数或正有理数，nil = 未
  声明）——工程 metadata 先例同 tpqn：内核存而不解释，仅帧 warp 换算
  消费（§5 第 4 条）；帧域 Metric 锚上 tick 轨以其已声明为前提。
- **`name` 是纯 annotation**：可变、可重复（不做唯一性校验）、可空
  （`nil`）；id 不可变，路由/锚/patch/版本钉永远只用 id。与
  `Pickle.Registry` 的轨型逻辑名是两个命名空间（实例显示名 vs 存档
  格式契约），判型永远按能力、绝不按 name。rename 是 mutation，入史为
  `rename_track` 命令边（§12.4）。Pickle：`name` 作可选
  字段进 dump，旧档缺失 load 为 `nil`——首个可选字段先例：格式兼容走
  "容忍缺失"档，而非版本号。`metadata`/`extras` 同样作为可选字段落盘，
  旧档缺失均回落 `%{}`；Pickle dump/load 两侧都复核 conform。
- behaviour 回调（7 个）：`coord_domain/0`、`cast_element/3`、
  `edit_element/2`（内容编辑的合并+重铸，`edit_note` lowering 经它一步
  写回）、`validate_gesture/3`（轨型政策挂载点：tempo 首元素保护、
  Audio 拒 merge/变长 drag、Vocal 同轨不重叠（2026-08-11 落地：半开
  区间，insert/drag/trim 的新 span 与 merge 的复合 span 不得压住其他
  存活音符，报 `{:vocal_overlap_rejected, _}`））、
  `split_elements/2`（切分两半的元素载荷，context 带几何——Audio 左半
  duration 收缩、右半 offset 重寻址）、`retime_element/3`（trim 的元素
  补偿钩子，`use` 默认 identity）、`view/1`（拍扁乐谱视图，§11.1）。
- 可选能力由 `Track.supports?/2` 按导出嗅探（不按 behaviour 声明）：
  `:tempo_derive`（`tempo_events/1`，§6 的 tempo 槽位绑定依据）；配套
  内嵌 behaviour（`Track.TempoDerive`）给编译期警告，能力自动被发现。
  元素归档 codec 不是轨型能力——`Pickle.ElementCodec` behaviour 与三个
  实现（Vocal/Tempo/Audio）都归 `Coconut.Pickle`，轨型 → codec 的绑定
  由 `Pickle.Registry` 注册项携带（`Registry.to_codec/2` 解析；未绑定且
  元素表非空报 `{:error, {:missing_element_codec, module}}`）。插件轨型
  （宿主自定义）提供自己的 codec 模块，注册时以 `codec:` 选项一并绑定。
- 已落地模块：`Track.Vocal`（Note 元素，tick 域）、`Track.Tempo`（bpm 裸
  map，tick 域）、`Track.Audio`（Clip 元素，帧域，见下）。`Track.Synth`
  留位（参数面比 Vocal 简单，不预留实现）。
- **Audio = 帧域轨道**：clip 的位置与内容都在帧/采样域——
  `source_offset_frames`/`duration_frames`，Space 的 span 也是帧。
  若用 tick 定位，span 随 tempo 编辑漂移，破坏 §4 "tick warp 与 tempo
  无关"硬约定；v1 不做 time-stretch（DAW 的 musical/linear 之辩以
  "帧域固定"收尾）。导入时经 TempoMap 换算落帧，之后 tempo 编辑不影响。
  音量自动化等干预拆两级：clip 级（Ordinal 锚 + clip 相对帧偏移）先行，
  轨级（帧域 Metric 锚 channel）所接的 v2 帧空间锚已落地（§5 第 4 条，
  含跟谱帧寻址语义与 echo transport）。
  **帧单位**：事实单位 = 渲染引擎的帧网格（DiffSinger 为声码器 hop 帧，
  `hop_size`/`sample_rate` 出 vocoder config），单位声明归引擎/工程
  metadata（工程级落点即 `Workspace.frame_rate`）；内核只见整数帧号、
  永不解释单位——§4 "帧/采样点 = 引擎层
  坐标"的具体化。不以 sample 为单位：sample→hop 的 round 会把 ±1 hop
  量化误差砸在 digest 零容差上。
- tempo 编辑的 Operation 同步：跨轨拖动 = 两轨各一次 apply_batch，
  `edit_version` 全局每批 +1，客户端两批之间需重读版本；多轨原子入口
  `apply_batches` 待跨轨拖动真做时再加。
- 渲染管线形状向 `CheckRequest -> Artifact[Conflict] -> RenderRequest`
  演进。
- 曲线模块（`Coconut.Curve.*`）收编为适配层曲线参数化库：payload 为
  控制点容器，rasterize 在消费边界；见
  design-2026-08-orchid-intervention.md §6.3。音量自动化即曲线，Audio
  落地时复用同一套。
- 在接 Oi（主要是 orchid_stratum）前，不用考虑数据缓存，唯一要考虑的是
  乐句分割。

**Track.Audio 操作集**：insert/delete/drag/split 复用通用手势（split 经
`split_elements/2`：右半 `source_offset += split - start`、左半 duration
收缩，纯整数帧算术）；trim = `TrimNote` 手势（Retime +
`retime_element/3` offset 反向补偿，Track 元素钩子，不进操作通用层）；
merge v1 拒绝（`:merge` 会诊报 `{:audio_merge_unsupported, _}`），变长
drag 拒绝（`:drag` 会诊报 `{:audio_stretch_rejected, _}`——span 长度恒
等于 `duration_frames`）。左缘越源头 trim 报
`{:audio_source_underflow, _}`（源长度是资产层知识，内核只守 offset
非负）。

## 12. Undo/Redo：Op 树 + 检查点

被否方案存档（防重复讨论；完整叙述见 git 历史与分支）：

- **inverse batch**（追加逆批次）：Delete 的逆需前状态（op 不含被删内容
  与 span），须在 lower/apply 当下同步捕获逆数据，op log 不再自足，
  且与跨轨原子提交纠缠。
- **快照栈**（双栈 past/future + 全量 Workspace 快照 + epoch 版本钉）：
  `future` 清空丢分支（分支试错是创作场景的真实需求）、放弃审计叙事、
  `epoch` 污染 Workspace 纯度（update 拒改 / Pickle 排除 / 测试断言例外
  三处税）。其快照机制被本方案吸收为检查点（§12.3）。

### 12.1 模型与语义

- History = 一棵 Op 树 + cursor：节点 = 状态（惰性物化），边 = 一条
  **已解析的写记录**（§12.4）。`present` 增量维护——写只发生在
  cursor，present = 旧 present + apply 一条边，O(1)、无 refold。
- 检查点：节点按需挂 Workspace 快照——**每 K 条边一个 + 每个分支
  节点一个**（只挂分支点不够：长链无分支时 fold 无界）。cursor 跳跃
  = 从目标后方最近检查点 fold 边序列，fold 长度 ≤ K。BEAM 结构共享
  使检查点近似免费。
- 逐比特等价的来源：靠**重放等价**证明——核心不变量：任意 cursor
  位置 `replay(最近检查点, 边路径)` == 实况 `present`。执法者为
  §12.6 的核心 property。
- 新手势、新写路径自动获得 undo：replay 只有正向 apply，无
  per-gesture 逆逻辑税（diff 适配器、Tempo.Ramp 均免费）；跨轨同撤
  （§8 跨 Space 重挂）= 一条边记录多轨批次（将来的 `apply_batches`）。
- **审计叙事回归**：树即完整手势史（含分支）；op log 语义不变（undo
  事件不进 log，叙事在 History 边而非 log）。每条边生成确定性
  gesture label（`Operations.*` struct 的纯函数），供历史面板/分支
  UI；LLM 语义 rollup 留壳层可选装饰（输入 = 分支的 label 序列），
  不进 lib、不进写路径。

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
  "undo 重写"更宽，epoch 方案（见文首存档）取消。History 是所有写
  的唯一入口（内在纪律，非可选惯例），钉 = History 签发的
  **cursor node id**；§11.5 的强制校验 = 壳比对 client 钉 ==
  cursor node id。`Snapshot` 加可选 `pin` 字段：壳经
  `History.current/1` 构造 Request 时填入 node id；裸
  `Snapshot.from_workspace/1`（lib 内部与测试用）留空、只钉
  `edit_version`，行为不变。`apply_batch` 的 `check_version` 不动
  （聚合内版本锁仍在），跨分支防误写由 History 写入口完成。
  Workspace 保持纯值、零例外字段；Pickle 字段列表不动。

### 12.3 放置、形状与生命周期

- 落点：独立包装 `Coconut.Edit.History`——树与检查点嵌进
  Workspace 需每层剥壳、语义混；包装层干净，且是壳（§10）的
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

1. **边上存解析后的记录，不是原始请求**：每条边是一个
   `Coconut.Edit.Command` 结构体（`op + payload + label`），载荷按
   op 解析落定——apply_batch 系 = lowered `ops + side_changes`；
   `attach_patches` = **mint 后的 patch**（id 落定）；`add_track` =
   **构造完成的 Track**（id 落定）；轻量字段边 = **全量新值**
   （rename / set_time_sigs）。解析在 `Command.execute/3` 内完成并
   以 resolved command 返回，History 挂树的是解析后形态；replay 只
   跑确定性 apply，不再 lower/mint/构造——`attach_patches` 的随机
   id minting 因此对重放无害。
2. **任何改状态的函数，要么是一条边，要么明确出局**：
   - 入史：`:batch`（九手势及未来一切批次——单轨与跨轨同构，载荷
     为按轨批次列表 `[{track_id, ops, side_changes}]`，经
     `History.apply/4` lower）与 `:attach_patches`（不 bump
     `edit_version`）。
   - **轨道结构写**入史为两种边：`:add_track`（载荷存完整
     Track；新建轨 = `{id, module}` + 空侧表，极小）与
     `:remove_track`（载荷为 track_id）。前向 replay = tracks map 的
     put/delete；**边里不存尸体**——被删轨道的全部内容由该边
     之前的边重建（undo 过删除点 = cursor 回到删除前，轨道自然
     在）；squash 后早期状态本就不可达，一致。tempo 轨是 `globals`
     全局轨（§6），不参与增删；`Workspace.new` 带入的初始轨道属
     root 状态，无需边。删非空轨 v1 允许——undo 经 replay 整体
     恢复其 elements / patches / 坟场（DAW 惯例，无重挂语义）。
     增删轨 bump `edit_version`（渲染产物随之变；规则表述：乐谱
     结构变化 bump，干预挂载不 bump）。
   - **轻量/扩展字段边**：`:rename_track`、`:put_track_metadata`、
     `:put_track_extras` 与 `:set_time_sigs`——无 Space 机器，边存全量新值，
     replay = 调对应纯函数。轨道名与 metadata 是 annotation，不 bump
     `edit_version`；extras 可能被宿主投影为合成输入，故每次整体替换 bump
     `edit_version`，防止旧 check/render 复用。中途变拍是乐谱手势（§6，
     不可撤销是真实的洞）；四者都入史。
   - resolve-time 冲突由策略决定是否丢弃；显式丢弃通过
     `:discard_patches` 边，把 `{track_id, patch_id, reason}` 指定的
     active patch 移入所属轨道坟场。不得由宿主直接改 Track struct。
     此边不 bump `edit_version`，与 attach 对称，可 undo/redo。
   - `take_dead_patches` 清坟场是 mutation（现状名为读取性操作）
     → 记 `:consume_dead` 边（解析后载荷 = 取走的
     `{patch, reason}` 元组；replay 不读载荷，重放实况 drain）。
     配套：策略层消费坟场按 `{patch.id, anchor.at_version}` 幂等
     去重——同一 patch 重挂后再死 at_version 不同，单按 id 去重
     会吞掉第二次死亡。
   - `Workspace.update/2`（收缩后只剩 `tpqn` 等工程级字段——
     `time_sigs` 已切出，见上）与 Project 层元数据：v1 声明出局——
     不受逐比特保证、不单独可撤（效果落在后续检查点里）；元数据
     撤销待 Project 层 before/after，另议。
   - 连带：`tracks` 是 Map、无序（`all_tracks` 明言 fold 序非语义）。
     将来 UI 需要轨道排序时，reorder 是新 mutation，同样必须是一条
     边——先记在这里，免得再漏。
3. **重放与实况共用同一 apply**：replay 与实况写都调
   `Command.execute/3` 这唯一分发表（内部分派到
   `Workspace.apply_batch` / `attach_patches` / `discard_patches` / `add_track` /
   `remove_track` / `rename_track` / `put_track_metadata` / `put_track_extras` /
   `set_time_sigs` 等纯函数），
   禁止 replay 专用分支（第二种实现 = 发散源）。

### 12.5 API 形状

- `Coconut.Edit.History`：`new/2`（包装现有 ws；opts 为
  `checkpoint_interval` / `max_edges` knob）、`apply/4`（手势写
  组合层：validate → lower → 执行 batch 命令，见 §12.3）、`run/3`
  （命令写路径：执行任意 `Coconut.Edit.Command`，记解析后形态）、
  `take_dead_patches/1`（记 `:consume_dead` 边，空 drain 不记边）、
  `undo/1` / `redo/1` → `{:ok, hist}` | `{:error, :nothing_to_undo |
  :nothing_to_redo}`、`current/1`（present + cursor node id，供壳
  构造 Request 时钉版本）、`state_at/2`（任意存活节点的物化状态，
  树 UI/分支枚举的地基）。写入口 opts 收 `:pin`（不等于当前 cursor
  即 `{:stale_pin, _}`，§12.2 的壳校验）；`apply/4` 另收 `:config`，
  `run/3` 另收 `:expected_version`。
- `Coconut.Edit.Command`：边记录结构体（`op / payload / label`）+
  各 op 构造器（`batch/2`、`attach_patches/1`、
  `discard_patches/1`、`add_track/1`（mint
  id + 构造 Track）、`remove_track/1`、`rename_track/2`、
  `set_time_sigs/1`、`consume_dead/0`）+ 唯一执行入口 `execute/3`
  （返回解析后 command；live 与 replay 共用，纪律 3）。新增写操作
  = 新 op 子句 + 构造器，History 零改动。
- 分支结构 API（子分支枚举等）v1 不暴露——树 UI 是壳层议题，
  届时再加。
- `History.apply/4` / `run/3` 是宿主安全写入口，负责
  validate → lower → Command → Workspace。Workspace 的
  `apply_batch/5` 等纯函数是 Command / Diff / 导入 / replay 使用的
  低层原语；提交仍检查可由完整状态判定的轨道 invariant（Vocal 不重叠、
  Audio no-stretch），但像 tempo 首事件保护这样的手势语义只能由安全
  入口保证。宿主不直接组合 `Operation.lower` 与 `Workspace.apply_batch`。
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
- 跨手势混合序列随机 round-trip（断言重放等价）。

### 12.7 宿主 Facade

- `Coconut` 是应用层统一入口；`Coconut.Session` 持有 History、channel
  注册、engine 配置、基础 interventions/globals 与最近一次 check round。
- 主路径为 `new → edit/run/mount → resolve/check/render`；undo/redo 和
  patch graveyard 也通过同一 session 穿线。任何 Workspace 写都会使旧
  check round 失效。
- `mount/6` 收走宿主重复实现的 Ordinal anchor 版本捕获、channel
  projection、Tamale digest、Patch 构造和入史挂载。
- `discard_conflicts/3` 把 Resolve entries 转成可重放的
  `:discard_patches` command；是否丢弃仍由宿主策略显式决定，Facade
  不默认吞冲突。
- `discard_patches/4` 覆盖 supersede 等尚未产生 Resolve entry 的显式
  策略丢弃，同样入史且可撤销；宿主不再直接改 Track 的 patch 列表。
- Project 只持久化当前 Workspace 与工程元数据；History、engine handle
  和 checked round 都是 session-scoped。由 Project 打开的 session 可用
  `Coconut.project/1` 导出当前状态。
- MusicXML/其他导入格式、声库发现与加载、WAV/调试文件落盘属于宿主，
  不进入 Facade，避免把一次性应用的策略重新固化进内核。
