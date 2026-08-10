defmodule Coconut.Pickle.Struct do
  @moduledoc """
  字段规格驱动的通用 struct codec 引擎。

  每个 `Coconut.Pickle.*` codec 声明一份字段规格（唯一真相），dump 与
  load 都从这里生成——领域改字段时只动声明，不再维护两个镜像函数。

  字段规格是 atom（原样直出/直入）或 `{field, handler}` 的列表。
  handler 原语：

  - `{:codec, Mod}` — 嵌套 codec（`Mod.dump/1` / `Mod.load/1`）；
  - `{:codec, Mod, :with_ctx}` — 注入上下文的嵌套 codec
    （`Mod.dump/2` / `Mod.load/2`，如 registry）；
  - `{:list, handler}` / `{:map_values, handler}` — 集合包装；
  - `{:tuple, schema}` — 位置 tuple，走 `Coconut.Pickle.TupleCodec`；
  - `{:conform, tag}` — 原样透传但两侧都过 `pickle_conform?/1`，
    失败报 `{tag, value}`（自由用户内容的约定，如 metadata）；
  - `{dump_fun, load_fun}` — 全自定义逃逸口（如带模块标签的
    Tamale struct 摊平）。

  错误契约：

  - dump 收到非本 struct 的值：`{:invalid_<resource>, value}`；
  - load 收到非 map：`{:invalid_<resource>_dump, value}`；
    `<resource>` 由模块名推导（`Coconut.Edit.Workspace` → `:workspace`）；
  - 集合字段形状不符（非 list / 非 map）：
    `{:invalid_<field>_dump, value}`；
  - 嵌套 codec / TupleCodec / 自定义 fun 的错误原样向上传播。

  load 用声明字段重建 attrs（缺失键为 `nil`，多余键忽略——map 是开放
  记录，向后兼容靠缺键容忍，对照 TupleCodec 的封闭形状严格性），最后
  调 `module.new/1`——领域校验在终点生效（parse, don't validate）。
  """

  alias Coconut.Pickle.TupleCodec

  import Coconut.Pickle, only: [pickle_conform?: 1]

  @type field_spec :: atom() | {atom(), handler()}

  @type handler ::
          {:codec, module()}
          | {:codec, module(), :with_ctx}
          | {:list, handler()}
          | {:map_values, handler()}
          | {:tuple, TupleCodec.schema()}
          | {:conform, tag :: atom()}
          | {dump :: (term() -> {:ok, term()} | {:error, term()}),
             load :: (term() -> {:ok, term()} | {:error, term()})}

  @doc "按字段规格把 struct 摊平为 plain map（`ctx` 透传给 `:with_ctx` handler）。"
  @spec dump(module(), term(), [field_spec()], term()) :: {:ok, map()} | {:error, term()}
  def dump(module, struct, fields, ctx \\ nil)

  def dump(module, %module{} = struct, fields, ctx) do
    Enum.reduce_while(fields, {:ok, %{}}, fn spec, {:ok, acc} ->
      {field, handler} = split(spec)

      case dump_field(field, Map.fetch!(struct, field), handler, ctx) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  def dump(module, other, _fields, _ctx), do: {:error, {resource_tag(module, :dump), other}}

  @doc "按字段规格从 plain map 重建 struct（经 `module.new/1`，校验生效）。"
  @spec load(module(), term(), [field_spec()], term()) :: {:ok, struct()} | {:error, term()}
  def load(module, data, fields, ctx \\ nil)

  def load(module, data, fields, ctx) when is_map(data) do
    fields
    |> Enum.reduce_while({:ok, %{}}, fn spec, {:ok, acc} ->
      {field, handler} = split(spec)

      case load_field(field, Map.get(data, field), handler, ctx) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> then(fn
      {:ok, attrs} -> module.new(attrs)
      err -> err
    end)
  end

  def load(module, other, _fields, _ctx), do: {:error, {resource_tag(module, :load), other}}

  # ---- handlers ----

  defp split(field) when is_atom(field), do: {field, nil}
  defp split({field, handler}) when is_atom(field), do: {field, handler}

  defp dump_field(_field, value, nil, _ctx), do: {:ok, value}
  defp dump_field(_field, value, {:codec, mod}, _ctx), do: mod.dump(value)
  defp dump_field(_field, value, {:codec, mod, :with_ctx}, ctx), do: mod.dump(value, ctx)

  defp dump_field(_field, value, {:tuple, schema}, _ctx),
    do: {:ok, TupleCodec.dump(value, schema)}

  defp dump_field(_field, value, {:conform, tag}, _ctx), do: conform(value, tag)

  defp dump_field(field, value, {:list, _} = coll, ctx),
    do: collect(value, field, coll, ctx, :dump)

  defp dump_field(field, value, {:map_values, _} = coll, ctx),
    do: collect(value, field, coll, ctx, :dump)

  defp dump_field(_field, value, {dump_fun, _load_fun}, _ctx)
       when is_function(dump_fun, 1),
       do: dump_fun.(value)

  defp load_field(_field, value, nil, _ctx), do: {:ok, value}
  defp load_field(_field, value, {:codec, mod}, _ctx), do: mod.load(value)
  defp load_field(_field, value, {:codec, mod, :with_ctx}, ctx), do: mod.load(value, ctx)
  defp load_field(_field, value, {:tuple, schema}, _ctx), do: TupleCodec.load(value, schema)
  defp load_field(_field, value, {:conform, tag}, _ctx), do: conform(value, tag)

  defp load_field(field, value, {:list, _} = coll, ctx),
    do: collect(value, field, coll, ctx, :load)

  defp load_field(field, value, {:map_values, _} = coll, ctx),
    do: collect(value, field, coll, ctx, :load)

  defp load_field(_field, value, {_dump_fun, load_fun}, _ctx)
       when is_function(load_fun, 1),
       do: load_fun.(value)

  # ---- collection wrappers ----

  defp collect(value, field, {:list, inner}, ctx, dir) do
    if is_list(value) do
      value
      |> collect_items(inner, ctx, dir, fn item -> {item, item} end)
      |> then(fn
        {:ok, acc} -> {:ok, acc |> Enum.reverse() |> Enum.map(fn {_key, item} -> item end)}
        err -> err
      end)
    else
      {:error, {field_tag(field), value}}
    end
  end

  defp collect(value, field, {:map_values, inner}, ctx, dir) do
    if is_map(value) do
      value
      |> collect_items(inner, ctx, dir, fn {key, item} -> {key, item} end)
      |> then(fn
        {:ok, acc} -> {:ok, Map.new(acc)}
        err -> err
      end)
    else
      {:error, {field_tag(field), value}}
    end
  end

  # 统一折叠为 {key, value} pair 列表；pairer 由集合类型显式给定
  # （dump 侧 list 元素可能是 tuple，绝不能靠形状猜）
  defp collect_items(enum, inner, ctx, dir, pairer) do
    Enum.reduce_while(enum, {:ok, []}, fn entry, {:ok, acc} ->
      {key, item} = pairer.(entry)

      case apply_inner(item, inner, ctx, dir) do
        {:ok, value} -> {:cont, {:ok, [{key, value} | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp apply_inner(item, inner, ctx, :dump), do: dump_field(nil, item, inner, ctx)
  defp apply_inner(item, inner, ctx, :load), do: load_field(nil, item, inner, ctx)

  # ---- misc ----

  defp conform(value, tag) do
    if pickle_conform?(value), do: {:ok, value}, else: {:error, {tag, value}}
  end

  # `Coconut.Edit.Workspace` → dump 侧 :invalid_workspace，load 侧 :invalid_workspace_dump
  defp resource_tag(module, :dump), do: String.to_atom("invalid_#{resource(module)}")
  defp resource_tag(module, :load), do: String.to_atom("invalid_#{resource(module)}_dump")

  defp resource(module), do: module |> Module.split() |> List.last() |> Macro.underscore()

  defp field_tag(field), do: String.to_atom("invalid_#{field}_dump")
end
