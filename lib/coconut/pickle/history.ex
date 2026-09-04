defmodule Coconut.Pickle.History do
  @moduledoc """
  `Coconut.Edit.History` 的原生对象 codec（arity-2：`dump/2` / `load/2`，
  registry 注入——节点 checkpoint 与 `:add_track` record 需要它）。

  dump 为摊平的 map：

  - `nodes` — `%{seq => node}`（整数键是约定允许的 map 键类型）；node 的
    `record` 走 `Coconut.Pickle.Command` codec（nil 直出——root 与 squash
    frontier 无 record），`checkpoint` 走 `Coconut.Pickle.Workspace` codec
    （nil 直出），`parent` / `label` / `timestamp` 原样直出；
  - `cursor` / `seq` / `base_seq` / `checkpoint_interval` / `max_edges`
    原样直出；
  - `present` **不入档**——load 终点是 `Coconut.Edit.History.restore/1`，
    从 cursor 最近的 checkpoint 重 fold 派生 present（replay 与 live 共用
    `Command.execute/3`，§12.4），窗口不变量在 restore 复检。

  load 对未知/非法形状返回 error tuple，不 raise。
  """

  alias Coconut.Edit.History
  alias Coconut.Edit.Command, as: EditCommand
  alias Coconut.Pickle.{Registry, Workspace}
  alias Coconut.Pickle.Command, as: CommandCodec

  @spec dump(History.t(), Registry.t()) :: {:ok, map()} | {:error, term()}
  def dump(%History{} = hist, %Registry{} = registry) do
    with {:ok, nodes} <- dump_nodes(hist.nodes, registry) do
      {:ok,
       %{
         nodes: nodes,
         cursor: hist.cursor,
         seq: hist.seq,
         base_seq: hist.base_seq,
         checkpoint_interval: hist.checkpoint_interval,
         max_edges: hist.max_edges
       }}
    end
  end

  def dump(other, %Registry{}), do: {:error, {:invalid_history, other}}

  @spec load(term(), Registry.t()) :: {:ok, History.t()} | {:error, term()}
  def load(%{} = data, %Registry{} = registry) do
    with {:ok, nodes} <- load_nodes(Map.get(data, :nodes), registry) do
      History.restore(%{
        nodes: nodes,
        cursor: Map.get(data, :cursor),
        seq: Map.get(data, :seq),
        base_seq: Map.get(data, :base_seq),
        checkpoint_interval: Map.get(data, :checkpoint_interval),
        max_edges: Map.get(data, :max_edges)
      })
    end
  end

  def load(other, %Registry{}), do: {:error, {:invalid_history_dump, other}}

  # ---- nodes ----

  defp dump_nodes(nodes, registry) when is_map(nodes) do
    nodes
    |> Enum.reduce_while({:ok, %{}}, fn {seq, node}, {:ok, acc} ->
      with {:ok, record} <- dump_record(node.record, registry),
           {:ok, checkpoint} <- dump_checkpoint(node.checkpoint, registry) do
        dumped = %{
          parent: node.parent,
          record: record,
          checkpoint: checkpoint,
          label: node.label,
          timestamp: node.timestamp
        }

        {:cont, {:ok, Map.put(acc, seq, dumped)}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp dump_nodes(other, _registry), do: {:error, {:invalid_history_nodes, other}}

  defp load_nodes(nodes, registry) when is_map(nodes) do
    nodes
    |> Enum.reduce_while({:ok, %{}}, fn {seq, node}, {:ok, acc} ->
      with true <- is_integer(seq) and is_map(node),
           {:ok, record} <- load_record(Map.get(node, :record), registry),
           {:ok, checkpoint} <- load_checkpoint(Map.get(node, :checkpoint), registry) do
        loaded = %{
          parent: Map.get(node, :parent),
          record: record,
          checkpoint: checkpoint,
          label: Map.get(node, :label),
          timestamp: Map.get(node, :timestamp)
        }

        {:cont, {:ok, Map.put(acc, seq, loaded)}}
      else
        {:error, _} = err -> {:halt, err}
        false -> {:halt, {:error, {:invalid_history_node_dump, {seq, node}}}}
      end
    end)
  end

  defp load_nodes(other, _registry), do: {:error, {:invalid_history_nodes_dump, other}}

  # ---- record / checkpoint（nil 直出：root 与 squash frontier 无 record）----

  defp dump_record(nil, _registry), do: {:ok, nil}
  defp dump_record(%EditCommand{} = record, registry), do: CommandCodec.dump(record, registry)
  defp dump_record(other, _registry), do: {:error, {:invalid_history_record, other}}

  defp load_record(nil, _registry), do: {:ok, nil}
  defp load_record(record, registry), do: CommandCodec.load(record, registry)

  defp dump_checkpoint(nil, _registry), do: {:ok, nil}

  defp dump_checkpoint(%Coconut.Edit.Workspace{} = checkpoint, registry),
    do: Workspace.dump(checkpoint, registry)

  defp dump_checkpoint(other, _registry), do: {:error, {:invalid_history_checkpoint, other}}

  defp load_checkpoint(nil, _registry), do: {:ok, nil}
  defp load_checkpoint(checkpoint, registry), do: Workspace.load(checkpoint, registry)
end
