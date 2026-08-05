defmodule Coconut.Pickle.Anchor do
  @moduledoc """
  `Tamale.Anchor` 三种 struct（Ordinal / Metric / Relative）的原生对象 codec。

  dump 为带 `module` 标签的单一 map（`%{module: 模块atom, ...各字段}`），
  各字段基本直出，两处例外：

  - 有理数坐标 `{num, den}`（Metric 的 `from`/`to`、Relative 的
    `from_offset`/`to_offset`）编码为二元 list `[num, den]`；裸整数坐标原样直出。
    load 按形态还原：整数 → 整数，二元整数 list → `{num, den}`。
  - Metric 的 `coord` 标签：atom（`:tick`、`:dynamic_tick` 等 sentinel）原样透传；
    `{:frames, hz}` 之类的二元 tuple 编码为二元 list，load 还原为 tuple。

  tamale 未提供 Anchor 的构造/校验函数，load 按 `module` 标签白名单分发
  `struct/2` 重建；未知标签或非法字段返回 `{:error, {:invalid_anchor_dump, _}}`，
  不 raise。
  """

  @behaviour Coconut.Pickle

  alias Tamale.Anchor.{Metric, Ordinal, Relative}

  @impl true
  def dump(%Ordinal{} = anchor) do
    {:ok,
     %{
       module: Ordinal,
       refs: anchor.refs,
       adjacent?: anchor.adjacent?,
       at_version: anchor.at_version
     }}
  end

  def dump(%Metric{} = anchor) do
    {:ok,
     %{
       module: Metric,
       coord: dump_coord_tag(anchor.coord),
       from: dump_coord(anchor.from),
       to: dump_coord(anchor.to),
       at_version: anchor.at_version
     }}
  end

  def dump(%Relative{} = anchor) do
    {:ok,
     %{
       module: Relative,
       ref: anchor.ref,
       from_offset: dump_coord(anchor.from_offset),
       to_offset: dump_coord(anchor.to_offset),
       at_version: anchor.at_version
     }}
  end

  def dump(other), do: {:error, {:invalid_anchor, other}}

  @impl true
  def load(%{module: Ordinal, refs: refs, adjacent?: adjacent?, at_version: at_version})
      when is_list(refs) and is_boolean(adjacent?) and is_integer(at_version) do
    {:ok, %Ordinal{refs: refs, adjacent?: adjacent?, at_version: at_version}}
  end

  def load(%{module: Metric, at_version: at_version} = data) when is_integer(at_version) do
    with {:ok, coord} <- load_coord_tag(Map.get(data, :coord)),
         {:ok, from} <- load_coord(Map.get(data, :from)),
         {:ok, to} <- load_coord(Map.get(data, :to)) do
      {:ok, %Metric{coord: coord, from: from, to: to, at_version: at_version}}
    else
      _ -> {:error, {:invalid_anchor_dump, data}}
    end
  end

  def load(%{module: Relative, ref: ref, at_version: at_version} = data)
      when is_integer(at_version) do
    with {:ok, from_offset} <- load_coord(Map.get(data, :from_offset)),
         {:ok, to_offset} <- load_coord(Map.get(data, :to_offset)) do
      {:ok,
       %Relative{ref: ref, from_offset: from_offset, to_offset: to_offset, at_version: at_version}}
    else
      _ -> {:error, {:invalid_anchor_dump, data}}
    end
  end

  def load(other), do: {:error, {:invalid_anchor_dump, other}}

  # 有理数坐标 {num, den} → [num, den]；其余（整数等）原样直出
  defp dump_coord({num, den}), do: [num, den]
  defp dump_coord(other), do: other

  # coord 标签的二元 tuple（如 {:frames, hz}）→ [a, b]；atom/nil 原样透传
  defp dump_coord_tag({a, b}), do: [a, b]
  defp dump_coord_tag(other), do: other

  defp load_coord(n) when is_integer(n), do: {:ok, n}

  defp load_coord([num, den]) when is_integer(num) and is_integer(den),
    do: {:ok, {num, den}}

  defp load_coord(other), do: {:error, {:invalid_coord_dump, other}}

  defp load_coord_tag(tag) when is_atom(tag), do: {:ok, tag}
  defp load_coord_tag([a, b]), do: {:ok, {a, b}}
  defp load_coord_tag(other), do: {:error, {:invalid_coord_tag_dump, other}}
end
