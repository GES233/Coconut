defmodule Coconut.Pickle.TupleCodec do
  @moduledoc """
  位置 tuple ↔ 语义 map 的双向 converter，由名字 schema 驱动。

  schema 为 `{name, fields}`：field 是 atom（叶子）或嵌套 schema（该
  位置本身是个 tuple）。例——`{bar, {num, den}}` 的 schema：

      {:time_sig, [:bar, {:sig, [:num, :den]}]}

  - `dump/2`：tuple 树按 schema zip 成 map 树（`{1, {4, 4}}` →
    `%{bar: 1, sig: %{num: 4, den: 4}}`）。dump 假定输入已过领域校验
    （所有领域对象由 `new/1` 产出），形状与 schema 不符属编程错误，
    raise `ArgumentError`；
  - `load/2`：map 树解析回 tuple 树——parse, don't validate。只查
    形状（非 map、缺 key、多 key 均失败），报
    `{:error, {:invalid_<name>_dump, value}}`，嵌套层报嵌套 schema
    自己的 tag；叶子值不做类型检查，领域合法性留在下游——所有
    load 路径的终点都是模型的 `new/1` 校验（见 `Coconut.Pickle`）。
  """

  @type schema :: {name :: atom(), [field()]}
  @type field :: atom() | schema()

  @doc "按 schema 把 tuple 树 zip 成 map 树。形状不符属编程错误，raise。"
  @spec dump(term(), schema()) :: map()
  def dump(tuple, {name, fields}) do
    unless is_tuple(tuple) and tuple_size(tuple) == length(fields) do
      raise ArgumentError,
            "invalid #{name} shape: expected a #{length(fields)}-tuple, got: #{inspect(tuple)}"
    end

    tuple
    |> Tuple.to_list()
    |> Enum.zip(fields)
    |> Map.new(fn
      {value, field} when is_atom(field) -> {field, value}
      {value, {field, _} = nested} -> {field, dump(value, nested)}
    end)
  end

  @doc "把 map 树解析回 tuple 树；形状不符报 `{:invalid_<name>_dump, value}`。"
  @spec load(term(), schema()) :: {:ok, tuple()} | {:error, term()}
  def load(map, {name, fields}) when is_map(map) do
    if Enum.sort(Map.keys(map)) == sorted_names(fields) do
      parse_fields(map, fields)
    else
      {:error, {invalid_tag(name), map}}
    end
  end

  def load(other, {name, _fields}), do: {:error, {invalid_tag(name), other}}

  defp parse_fields(map, fields) do
    fields
    |> Enum.reduce_while({:ok, []}, fn field, {:ok, acc} ->
      case parse_field(Map.fetch!(map, name_of(field)), field) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> then(fn
      {:ok, values} -> {:ok, values |> Enum.reverse() |> List.to_tuple()}
      err -> err
    end)
  end

  defp parse_field(value, field) when is_atom(field), do: {:ok, value}
  defp parse_field(value, {_name, _} = nested), do: load(value, nested)

  defp name_of(field) when is_atom(field), do: field
  defp name_of({name, _fields}), do: name

  defp sorted_names(fields), do: fields |> Enum.map(&name_of/1) |> Enum.sort()

  defp invalid_tag(name), do: String.to_atom("invalid_#{name}_dump")
end
