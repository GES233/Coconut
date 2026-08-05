defmodule Coconut.Pickle do
  @moduledoc """
  原生对象序列化（dump/load codec）约定，移植自 equinox 的 Pickle codec
  （`equinox/domain/lib/equinox_domain/pickle.ex`——design doc §9.5 指定的参照）。

  每种类型一对 `dump/1` / `load/1`：

  - `dump(struct) :: {:ok, map()} | {:error, term()}`
  - `load(map) :: {:ok, struct()} | {:error, term()}`

  coconut / tamale 自有 struct 的 codec 统一放在 `Coconut.Pickle.*` 下；
  load 一律经各模型的 `new/1`（或等价构造校验）重建，不直接 `struct!/2`。

  ## dump 产物的允许类型

  只允许：**map、list、number、binary、atom、boolean、nil**。

  禁止 **tuple / struct / fun / pid**：tuple 一律编码为 list（如 `[a, b, c]`），
  struct 一律摊平为 map（带 `module` 标签）。map 键允许 atom / binary / integer
  （如 Note.metadata 的 binary 键），其余键类型同样禁止。

  满足本约定的产物可直接 `:erlang.term_to_binary/1` 落盘，
  将来转 JSON 也只是机械转换，不需要额外 codec 层。

  ## 契约

  - `Note.metadata` 按 `Coconut.Score.Note` 的类型约定本身必须可序列化
    （本 codec 对它只做原样透传，不做深度规整）。
  - tempo 轨元素是无 struct 的裸 map（整数 milli-bpm），原样透传。
  - `Patch.payload` 由各 channel 契约保证可 dump
    （当前 pitch/duration 为 `[[tick, midi]]` 稀疏数组），原样透传。
  """

  @doc "把领域 struct 摊平为仅含允许类型的 plain map。"
  @callback dump(term()) :: {:ok, map()} | {:error, term()}

  @doc "从 plain map 重建领域 struct（经各模型的 new/1 校验）。"
  @callback load(map()) :: {:ok, term()} | {:error, term()}
end
