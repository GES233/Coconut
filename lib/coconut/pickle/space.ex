defmodule Coconut.Pickle.Space do
  @moduledoc """
  `Tamale.Space` 的原生对象 codec。

  dump 为摊平的 map，五个字段：

  - `ids` / `version` / `base_version` 原样直出；
  - `log` 是 `[{version, [Op]}]` 元组列表，dump 为
    `[[version, [op_dump, ...]], ...]`，op 走 `Coconut.Pickle.Op` codec；
  - `seen` 是 MapSet，dump 为排序后的 list（`Enum.sort/1`，保证 dump
    确定性），load 经 `MapSet.new/1` 还原。

  `Tamale.Space.new/1` 只建 genesis 空间（version 0、空 log），无法还原
  全量状态，故 load 直接 `struct/2` 重建（log 条目还原为 `{version, ops}`
  tuple）。未知形状或非法 log 条目返回 `{:error, {:invalid_space_dump, _}}`，
  不 raise。
  """

  @behaviour Coconut.Pickle

  alias Coconut.Pickle.Op, as: PickleOp
  alias Tamale.Space

  @impl true
  def dump(%Space{} = space) do
    with {:ok, log} <- dump_log(space.log) do
      {:ok,
       %{
         ids: space.ids,
         version: space.version,
         log: log,
         base_version: space.base_version,
         seen: space.seen |> MapSet.to_list() |> Enum.sort()
       }}
    end
  end

  def dump(other), do: {:error, {:invalid_space, other}}

  @impl true
  def load(%{ids: ids, version: version, log: log, base_version: base_version, seen: seen} = data)
      when is_list(ids) and is_integer(version) and is_list(log) and is_integer(base_version) and
             is_list(seen) do
    case load_log(log) do
      {:ok, entries} ->
        {:ok,
         %Space{
           ids: ids,
           version: version,
           log: entries,
           base_version: base_version,
           seen: MapSet.new(seen)
         }}

      {:error, _} ->
        {:error, {:invalid_space_dump, data}}
    end
  end

  def load(other), do: {:error, {:invalid_space_dump, other}}

  # log 条目 {version, ops} → [version, [op_dump, ...]]
  defp dump_log(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn {version, ops}, {:ok, acc} ->
      case dump_ops(ops) do
        {:ok, dumped} -> {:cont, {:ok, [[version, dumped] | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> then(fn
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end)
  end

  defp dump_ops(ops) when is_list(ops) do
    Enum.reduce_while(ops, {:ok, []}, fn op, {:ok, acc} ->
      case PickleOp.dump(op) do
        {:ok, dumped} -> {:cont, {:ok, [dumped | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> then(fn
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end)
  end

  # log 条目 [version, [op_dump, ...]] → {version, ops}
  defp load_log(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case load_entry(entry) do
        {:ok, loaded} -> {:cont, {:ok, [loaded | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> then(fn
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end)
  end

  defp load_entry([version, ops]) when is_integer(version) and is_list(ops) do
    Enum.reduce_while(ops, {:ok, []}, fn op_dump, {:ok, acc} ->
      case PickleOp.load(op_dump) do
        {:ok, op} -> {:cont, {:ok, [op | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> then(fn
      {:ok, acc} -> {:ok, {version, Enum.reverse(acc)}}
      err -> err
    end)
  end

  defp load_entry(other), do: {:error, {:invalid_log_entry_dump, other}}
end
