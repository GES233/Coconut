defmodule Coconut.Pickle do
  @moduledoc """
  Defines a serialization contract for domain structs.

  The `dump/1` callback serializes a struct into a plain `serialized` value,
  and `load/1` reconstructs the struct from such a value.

  `serialized` allows only the following types: map, list, number, binary, atom, boolean, nil.
  Nested structures are allowed.

  Each model should implement its own codec under `Coconut.Pickle.*`.
  `load/1` should use the model's `new/1` (or equivalent) for validation, not `struct!/2`.

  ## dump 产物的允许类型

  只允许：**map、list、number、binary、atom、boolean、nil**。

  禁止 **tuple / struct / fun / pid**：tuple 一律编码为 list（如 `[a, b, c]`），
  struct 一律摊平为 map（带 `module` 标签）。map 键允许 atom / binary / integer
  （如 Note.metadata 的 binary 键），其余键类型同样禁止。

  满足本约定的产物可直接 `:erlang.term_to_binary/1` 落盘，
  将来转 JSON 也只是机械转换，不需要额外 codec 层。
  """

  @type serialized_key :: atom() | binary() | integer()
  @type serialized ::
          map()
          | list(serialized)
          | number()
          | binary()
          | atom()
          | boolean()
          | nil

  @doc "Dumps a domain struct into a plain serialized map."
  @callback dump(term()) :: {:ok, serialized()} | {:error, term()}

  @doc "Loads a domain struct from a plain serialized map."
  @callback load(serialized()) :: {:ok, term()} | {:error, term()}
end
