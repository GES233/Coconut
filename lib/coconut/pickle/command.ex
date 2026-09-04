defmodule Coconut.Pickle.Command do
  @moduledoc """
  `Coconut.Edit.Command`（History 树节点的已解析写入记录）的原生对象
  codec（arity-2：`dump/2` / `load/2`，registry 注入——`:add_track` 的
  payload 需要它解析轨型）。

  不实现 `Coconut.Pickle` behaviour：需要注入 registry 的 codec 用
  同风格 arity-2 签名（对照 `Coconut.Pickle.Track`）。

  dump 为摊平的 map `%{op, payload, label}`，`payload` 按 op 分派：

  - `:batch` — `[%{track_id, ops, side_changes}]`；ops 走
    `Coconut.Pickle.Op`，side_changes 的 `elements`/`patches_remove`
    原样透传（须满足 `Coconut.Pickle` 约定），`span_snapshot` 的 span 走
    `Coconut.Pickle.TupleCodec`，`patches_add` 走 `Coconut.Pickle.Patch`；
  - `:attach_patches` / `:repatch_patches` — Patch 走
    `Coconut.Pickle.Patch`，discard 三元组 `{track_id, patch_id, reason}`
    编码为 map（reason 透传但须 conform，同 dead_patches 约定）；
  - `:add_track` — 走 `Coconut.Pickle.Track` codec（registry 解析轨型）；
  - `:discard_patches` / `:remove_track` / `:rename_track` /
    `:put_track_metadata` / `:put_track_extras` — plain 数据直出
    （tuple 一律降为 map/list）；
  - `:set_time_sigs` — `[{bar, {num, den}}]` 走 TupleCodec（spec 与
    `Coconut.Pickle.Workspace` 一致）；
  - `:consume_dead` — `{patch, reason}` 编码为 `%{patch, reason}`
    （replay 忽略该 payload 重新 drain，存档仅为保真）。

  load 按 `op` 白名单分派重建；未知 op 或非法字段返回
  `{:error, {:invalid_command_dump, _}}`，不 raise。
  """

  alias Coconut.Edit.Command
  alias Coconut.Edit.Track, as: EditTrack
  alias Coconut.Pickle.{Op, Patch, Registry, Track, TupleCodec}

  import Coconut.Pickle, only: [pickle_conform?: 1]

  @span {:span, [:start, :stop]}
  @time_sig {:time_sig, [:bar, {:sig, [:num, :den]}]}

  @spec dump(Command.t(), Registry.t()) :: {:ok, map()} | {:error, term()}
  def dump(%Command{} = command, %Registry{} = registry) do
    with {:ok, payload} <- dump_payload(command.op, command.payload, registry) do
      {:ok, %{op: command.op, payload: payload, label: command.label}}
    end
  end

  def dump(other, %Registry{}), do: {:error, {:invalid_command, other}}

  @spec load(term(), Registry.t()) :: {:ok, Command.t()} | {:error, term()}
  def load(%{op: op, payload: payload} = data, %Registry{} = registry) do
    with {:ok, payload} <- load_payload(op, payload, registry) do
      {:ok, %Command{op: op, payload: payload, label: Map.get(data, :label) || "Edit"}}
    end
  end

  def load(other, %Registry{}), do: {:error, {:invalid_command_dump, other}}

  # ---- dump：payload 按 op 分派 ----

  defp dump_payload(:batch, batches, registry) when is_list(batches) do
    batches
    |> Enum.reduce_while({:ok, []}, fn {track_id, ops, side_changes}, {:ok, acc} ->
      with {:ok, ops} <- dump_ops(ops),
           {:ok, side_changes} <- dump_side_changes(side_changes, registry) do
        entry = %{track_id: track_id, ops: ops, side_changes: side_changes}
        {:cont, {:ok, [entry | acc]}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> reverse_result()
  end

  defp dump_payload(:attach_patches, patches, _registry), do: dump_patches(patches)

  defp dump_payload(:repatch_patches, {discards, patches}, _registry) do
    with {:ok, discards} <- dump_discards(discards),
         {:ok, patches} <- dump_patches(patches) do
      {:ok, %{discards: discards, patches: patches}}
    end
  end

  defp dump_payload(:discard_patches, discards, _registry), do: dump_discards(discards)

  defp dump_payload(:add_track, %EditTrack{} = track, registry),
    do: Track.dump(track, registry)

  defp dump_payload(:remove_track, track_id, _registry), do: conform(track_id, :remove_track)

  defp dump_payload(:rename_track, {track_id, name}, _registry),
    do: {:ok, %{track_id: track_id, name: name}}

  defp dump_payload(op, {track_id, value}, _registry)
       when op in [:put_track_metadata, :put_track_extras] do
    with :ok <- check_conform(value, op) do
      {:ok, %{track_id: track_id, value: value}}
    end
  end

  defp dump_payload(:set_time_sigs, events, _registry) when is_list(events),
    do: {:ok, Enum.map(events, &TupleCodec.dump(&1, @time_sig))}

  # :consume_dead 的 resolved payload 是 drain 出来的 {patch, reason} 列表；
  # replay 忽略该 payload（重新 drain），存档仅为保真。
  defp dump_payload(:consume_dead, dead, _registry) when is_list(dead) do
    dead
    |> Enum.reduce_while({:ok, []}, fn {patch, reason}, {:ok, acc} ->
      with {:ok, dumped} <- Patch.dump(patch),
           :ok <- check_conform(reason, :dead_reason) do
        {:cont, {:ok, [%{patch: dumped, reason: reason} | acc]}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> reverse_result()
  end

  defp dump_payload(op, payload, _registry), do: {:error, {:invalid_command_payload, op, payload}}

  # ---- load：payload 按 op 分派 ----

  defp load_payload(:batch, batches, registry) when is_list(batches) do
    batches
    |> Enum.reduce_while({:ok, []}, fn
      %{track_id: track_id, ops: ops, side_changes: side_changes}, {:ok, acc} ->
        with {:ok, ops} <- load_ops(ops),
             {:ok, side_changes} <- load_side_changes(side_changes, registry) do
          {:cont, {:ok, [{track_id, ops, side_changes} | acc]}}
        else
          {:error, _} = err -> {:halt, err}
        end

      other, _acc ->
        {:halt, {:error, {:invalid_batch_entry_dump, other}}}
    end)
    |> reverse_result()
  end

  defp load_payload(:attach_patches, patches, _registry), do: load_patches(patches)

  defp load_payload(:repatch_patches, %{discards: discards, patches: patches}, _registry) do
    with {:ok, discards} <- load_discards(discards),
         {:ok, patches} <- load_patches(patches) do
      {:ok, {discards, patches}}
    end
  end

  defp load_payload(:discard_patches, discards, _registry), do: load_discards(discards)

  defp load_payload(:add_track, data, registry), do: Track.load(data, registry)

  defp load_payload(:remove_track, track_id, _registry), do: conform(track_id, :remove_track)

  defp load_payload(:rename_track, %{track_id: track_id, name: name}, _registry),
    do: {:ok, {track_id, name}}

  defp load_payload(op, %{track_id: track_id, value: value}, _registry)
       when op in [:put_track_metadata, :put_track_extras] do
    with :ok <- check_conform(value, op) do
      {:ok, {track_id, value}}
    end
  end

  defp load_payload(:set_time_sigs, events, _registry) when is_list(events) do
    events
    |> Enum.reduce_while({:ok, []}, fn dumped, {:ok, acc} ->
      case TupleCodec.load(dumped, @time_sig) do
        {:ok, event} -> {:cont, {:ok, [event | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> reverse_result()
  end

  defp load_payload(:consume_dead, dead, _registry) when is_list(dead) do
    dead
    |> Enum.reduce_while({:ok, []}, fn
      %{patch: dumped, reason: reason}, {:ok, acc} ->
        with {:ok, patch} <- Patch.load(dumped),
             :ok <- check_conform(reason, :dead_reason) do
          {:cont, {:ok, [{patch, reason} | acc]}}
        else
          {:error, _} = err -> {:halt, err}
        end

      other, _acc ->
        {:halt, {:error, {:invalid_dead_patch_dump, other}}}
    end)
    |> reverse_result()
  end

  defp load_payload(op, payload, _registry), do: {:error, {:invalid_command_dump, op, payload}}

  # ---- side_changes ----

  defp dump_side_changes(%{} = sc, registry) do
    with {:ok, elements} <- dump_side_elements(sc.elements, registry),
         {:ok, spans} <- dump_span_snapshot(sc.span_snapshot),
         {:ok, patches} <- dump_patches(sc.patches_add),
         {:ok, removes} <- dump_patches(sc.patches_remove) do
      {:ok,
       %{
         elements: elements,
         span_snapshot: spans,
         patches_add: patches,
         patches_remove: removes
       }}
    end
  end

  defp dump_side_changes(other, _registry), do: {:error, {:invalid_side_changes, other}}

  defp load_side_changes(%{} = sc, registry) do
    with {:ok, elements} <- load_side_elements(Map.get(sc, :elements, %{}), registry),
         {:ok, spans} <- load_span_snapshot(Map.get(sc, :span_snapshot, %{})),
         {:ok, patches} <- load_patches(Map.get(sc, :patches_add, [])),
         {:ok, removes} <- load_patches(Map.get(sc, :patches_remove, [])) do
      {:ok,
       %{
         elements: elements,
         span_snapshot: spans,
         patches_add: patches,
         patches_remove: removes
       }}
    end
  end

  defp load_side_changes(other, _registry), do: {:error, {:invalid_side_changes_dump, other}}

  # 元素 upsert：struct 元素按 `__struct__` 经 registry 反查轨型 codec，
  # dump 为 %{element: 轨型逻辑名, data: codec 产物}（batch 只有 track_id
  # 没有轨型，轨道可能已被删除，这是唯一自包含的分派方式）；裸 map 元素
  # （Tempo 的 %{bpm: n}）原样透传但须 conform；:delete 墓碑直出。
  defp dump_side_elements(elements, registry) when is_map(elements) do
    elements
    |> Enum.reduce_while({:ok, %{}}, fn
      {id, :delete}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, id, :delete)}}

      {id, %{__struct__: element_module} = element}, {:ok, acc} ->
        with {:ok, {name, codec}} <- Registry.to_element_codec(registry, element_module),
             {:ok, data} <- codec.dump_element(element) do
          {:cont, {:ok, Map.put(acc, id, %{element: name, data: data})}}
        else
          {:error, _} = err -> {:halt, err}
        end

      {id, element}, {:ok, acc} ->
        case conform(element, :side_element) do
          {:ok, element} -> {:cont, {:ok, Map.put(acc, id, element)}}
          {:error, _} = err -> {:halt, err}
        end
    end)
  end

  defp dump_side_elements(other, _registry), do: {:error, {:invalid_side_elements, other}}

  defp load_side_elements(elements, registry) when is_map(elements) do
    elements
    |> Enum.reduce_while({:ok, %{}}, fn
      {id, :delete}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, id, :delete)}}

      {id, %{element: name, data: data}}, {:ok, acc} when is_binary(name) ->
        with {:ok, track_module} <- Registry.to_module(registry, name),
             {:ok, codec} <- Registry.to_codec(registry, track_module),
             {:ok, element} <- codec.load_element(data) do
          {:cont, {:ok, Map.put(acc, id, element)}}
        else
          {:error, _} = err -> {:halt, err}
        end

      {id, element}, {:ok, acc} ->
        case conform(element, :side_element_dump) do
          {:ok, element} -> {:cont, {:ok, Map.put(acc, id, element)}}
          {:error, _} = err -> {:halt, err}
        end
    end)
  end

  defp load_side_elements(other, _registry), do: {:error, {:invalid_side_elements_dump, other}}

  defp dump_span_snapshot(spans) when is_map(spans) do
    {:ok,
     Map.new(spans, fn
       {id, :delete} -> {id, :delete}
       {id, span} -> {id, TupleCodec.dump(span, @span)}
     end)}
  end

  defp dump_span_snapshot(other), do: {:error, {:invalid_span_snapshot, other}}

  defp load_span_snapshot(spans) when is_map(spans) do
    spans
    |> Enum.reduce_while({:ok, %{}}, fn
      {id, :delete}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, id, :delete)}}

      {id, dumped}, {:ok, acc} ->
        case TupleCodec.load(dumped, @span) do
          {:ok, span} -> {:cont, {:ok, Map.put(acc, id, span)}}
          {:error, _} = err -> {:halt, err}
        end
    end)
  end

  defp load_span_snapshot(other), do: {:error, {:invalid_span_snapshot_dump, other}}

  # ---- 集合助手 ----

  defp dump_ops(ops) when is_list(ops) do
    ops
    |> Enum.reduce_while({:ok, []}, fn op, {:ok, acc} ->
      case Op.dump(op) do
        {:ok, dumped} -> {:cont, {:ok, [dumped | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> reverse_result()
  end

  defp dump_ops(other), do: {:error, {:invalid_ops, other}}

  defp load_ops(ops) when is_list(ops) do
    ops
    |> Enum.reduce_while({:ok, []}, fn dumped, {:ok, acc} ->
      case Op.load(dumped) do
        {:ok, op} -> {:cont, {:ok, [op | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> reverse_result()
  end

  defp load_ops(other), do: {:error, {:invalid_ops_dump, other}}

  defp dump_patches(patches) when is_list(patches) do
    patches
    |> Enum.reduce_while({:ok, []}, fn patch, {:ok, acc} ->
      case Patch.dump(patch) do
        {:ok, dumped} -> {:cont, {:ok, [dumped | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> reverse_result()
  end

  defp dump_patches(other), do: {:error, {:invalid_patches, other}}

  defp load_patches(patches) when is_list(patches) do
    patches
    |> Enum.reduce_while({:ok, []}, fn dumped, {:ok, acc} ->
      case Patch.load(dumped) do
        {:ok, patch} -> {:cont, {:ok, [patch | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> reverse_result()
  end

  defp load_patches(other), do: {:error, {:invalid_patches_dump, other}}

  # discard 三元组 {track_id, patch_id, reason} → map；reason 透传但须 conform。
  defp dump_discards(discards) when is_list(discards) do
    discards
    |> Enum.reduce_while({:ok, []}, fn {track_id, patch_id, reason}, {:ok, acc} ->
      case check_conform(reason, :discard_reason) do
        :ok ->
          entry = %{track_id: track_id, patch_id: patch_id, reason: reason}
          {:cont, {:ok, [entry | acc]}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> reverse_result()
  end

  defp dump_discards(other), do: {:error, {:invalid_discards, other}}

  defp load_discards(discards) when is_list(discards) do
    discards
    |> Enum.reduce_while({:ok, []}, fn
      %{track_id: track_id, patch_id: patch_id, reason: reason}, {:ok, acc} ->
        case check_conform(reason, :discard_reason) do
          :ok -> {:cont, {:ok, [{track_id, patch_id, reason} | acc]}}
          {:error, _} = err -> {:halt, err}
        end

      other, _acc ->
        {:halt, {:error, {:invalid_discard_dump, other}}}
    end)
    |> reverse_result()
  end

  defp load_discards(other), do: {:error, {:invalid_discards_dump, other}}

  defp conform(value, tag) do
    if pickle_conform?(value), do: {:ok, value}, else: {:error, {:"non_conform_#{tag}", value}}
  end

  defp check_conform(value, tag) do
    if pickle_conform?(value), do: :ok, else: {:error, {:"non_conform_#{tag}", value}}
  end

  defp reverse_result({:ok, acc}), do: {:ok, Enum.reverse(acc)}
  defp reverse_result(err), do: err
end
