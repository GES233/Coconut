defmodule Coconut.Pickle.Op do
  @moduledoc """
  `Tamale.Op` 六种 struct（Insert / Delete / Split / Merge / Move / Retime）
  的原生对象 codec。

  dump 为带 `module` 标签的单一 map（`%{module: 模块atom, ...各字段}`），
  id 类字段（`id` / `after_id` / `into` / `ids` / `children`）原样直出
  （`:head` 之类的 sentinel atom 透传）。唯一需要转换的是 Retime 的 span：

  - `old_span` / `new_span` 是 `{start, stop}` 二元 tuple，编码为二元 list
    `[start, stop]`；
  - 每个端点是 `Tamale.Coord` 输入：裸整数原样直出，有理数 `{num, den}`
    编码为二元 list `[num, den]`。load 按元素形态区分还原：整数 → 整数，
    二元整数 list → `{num, den}`；span 整体必须是二元 list，否则 error。

  tamale 未提供 Op 的构造/校验函数（合法性在 `Tamale.Space.apply_batch/2`
  落批时才判定），load 按 `module` 标签白名单分发 `struct/2` 重建；
  未知标签或非法字段返回 `{:error, {:invalid_op_dump, _}}`，不 raise。
  """

  @behaviour Coconut.Pickle

  alias Tamale.Op.{Delete, Insert, Merge, Move, Retime, Split}

  @impl true
  def dump(%Insert{} = op), do: {:ok, %{module: Insert, id: op.id, after_id: op.after_id}}

  def dump(%Delete{} = op), do: {:ok, %{module: Delete, id: op.id}}

  def dump(%Split{} = op), do: {:ok, %{module: Split, id: op.id, children: op.children}}

  def dump(%Merge{} = op), do: {:ok, %{module: Merge, ids: op.ids, into: op.into}}

  def dump(%Move{} = op), do: {:ok, %{module: Move, id: op.id, after_id: op.after_id}}

  def dump(%Retime{} = op) do
    {:ok,
     %{
       module: Retime,
       id: op.id,
       old_span: dump_span(op.old_span),
       new_span: dump_span(op.new_span)
     }}
  end

  def dump(other), do: {:error, {:invalid_op, other}}

  @impl true
  def load(%{module: Insert, id: id, after_id: after_id}),
    do: {:ok, %Insert{id: id, after_id: after_id}}

  def load(%{module: Delete, id: id}), do: {:ok, %Delete{id: id}}

  def load(%{module: Split, id: id, children: children}) when is_list(children),
    do: {:ok, %Split{id: id, children: children}}

  def load(%{module: Merge, ids: ids, into: into}) when is_list(ids),
    do: {:ok, %Merge{ids: ids, into: into}}

  def load(%{module: Move, id: id, after_id: after_id}),
    do: {:ok, %Move{id: id, after_id: after_id}}

  def load(%{module: Retime, id: id} = data) do
    with {:ok, old_span} <- load_span(Map.get(data, :old_span)),
         {:ok, new_span} <- load_span(Map.get(data, :new_span)) do
      {:ok, %Retime{id: id, old_span: old_span, new_span: new_span}}
    else
      _ -> {:error, {:invalid_op_dump, data}}
    end
  end

  def load(other), do: {:error, {:invalid_op_dump, other}}

  # span {start, stop} → [start, stop]；端点有理数 {num, den} → [num, den]
  defp dump_span({start, stop}), do: [dump_coord(start), dump_coord(stop)]
  defp dump_span(other), do: other

  defp dump_coord({num, den}), do: [num, den]
  defp dump_coord(other), do: other

  defp load_span([start, stop]) do
    with {:ok, start} <- load_coord(start),
         {:ok, stop} <- load_coord(stop) do
      {:ok, {start, stop}}
    end
  end

  defp load_span(other), do: {:error, {:invalid_span_dump, other}}

  defp load_coord(n) when is_integer(n), do: {:ok, n}

  defp load_coord([num, den]) when is_integer(num) and is_integer(den),
    do: {:ok, {num, den}}

  defp load_coord(other), do: {:error, {:invalid_coord_dump, other}}
end
