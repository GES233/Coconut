# Coconut🥥

> This lib is still in the early stages of development,
> and the API may undergo significant changes in later versions.

~~A headless SVS Editor~~ An engine-agnostic editor core that treats user intervention as first-class.

## 分层依赖规则

coconut 的模块按层组织，依赖只允许自下而上（上层可依赖下层，反之禁止）：

- **Score ← Edit ← Render ← 引擎适配**：Score 是乐谱值对象层；Edit 是编辑操作与轨道层；Render 是解析（Resolve）与通道（Channel）契约层；具体引擎实现（adapter）在最外层，通过 `Coconut.Render.Engine` / `Coconut.Render.Channel` / `Coconut.Render.Encoder` 契约接入，建议放在独立的 adapter 包中。
- **Pickle（存档）只依赖 Score / Edit / Util**：存档层通过 `:element_codec` 等能力回调向轨道委托元素编解码，不反向依赖 Render 或引擎模块。
- **Engines 命名空间**：仅存放 reference/test 引擎（`Coconut.Engines.Mock`，examples 依赖）；真实引擎实现不放本仓（DiffSinger 引擎全家已于 2026-08-09 迁出至 sibling 包 `coconut_diffsinger`）。

人工核查方式：运行 `mix xref graph --label compile`，检查是否存在指向上述反向的编译期依赖边（例如 Edit 层模块出现在 Pickle 层的依赖方中）。
