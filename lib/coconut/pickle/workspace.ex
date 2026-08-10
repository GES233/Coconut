defmodule Coconut.Pickle.Workspace do
  @moduledoc """
  `Coconut.Edit.Workspace` 的原生对象 codec（arity-2：`dump/2` / `load/2`）。

  与 `Coconut.Pickle.Track` 一样不实现 `Coconut.Pickle` behaviour——
  需要注入 registry 的 codec 用 arity-2 同风格签名。

  dump 为摊平的 map：

  - `id` / `edit_version` / `tpqn` 原样直出；
  - `tracks` / `globals` 两个 map 的键（track id）直出，每个 value 走
    `Coconut.Pickle.Track` codec；
  - `time_sigs` 是 `[{bar, {num, den}}]`，经 `Coconut.Pickle.TupleCodec`
    转为语义 map 列表 `[%{bar: _, sig: %{num: _, den: _}}, ...]`，
    load 反向解析回 tuple。

  load 还原后经 `Coconut.Edit.Workspace.new/1` 重建——`validate/1` 自然生效：
  全局轨命名空间、tempo 槽位能力、time_sigs 合法性都会被复检。
  """

  alias Coconut.Edit.Workspace
  alias Coconut.Pickle.{Registry, Track, TupleCodec}

  @time_sig {:time_sig, [:bar, {:sig, [:num, :den]}]}

  @doc "把 `Coconut.Edit.Workspace` 摊平为仅含允许类型的 plain map。"
  @spec dump(Workspace.t(), Registry.t()) :: {:ok, map()} | {:error, term()}
  def dump(%Workspace{} = ws, %Registry{} = registry) do
    with {:ok, tracks} <- dump_tracks(ws.tracks, registry),
         {:ok, globals} <- dump_tracks(ws.globals, registry) do
      {:ok,
       %{
         id: ws.id,
         edit_version: ws.edit_version,
         tracks: tracks,
         globals: globals,
         tpqn: ws.tpqn,
         time_sigs: dump_time_sigs(ws.time_sigs)
       }}
    end
  end

  def dump(other, %Registry{}), do: {:error, {:invalid_workspace, other}}

  @doc "从 plain map 重建 `Coconut.Edit.Workspace`（经 `Workspace.new/1`，校验生效）。"
  @spec load(map(), Registry.t()) :: {:ok, Workspace.t()} | {:error, term()}
  def load(%{} = data, %Registry{} = registry) do
    with {:ok, tracks} <- load_tracks(Map.get(data, :tracks), registry),
         {:ok, globals} <- load_globals(Map.get(data, :globals), registry),
         {:ok, time_sigs} <- load_time_sigs(Map.get(data, :time_sigs)) do
      %{
        id: Map.get(data, :id),
        edit_version: Map.get(data, :edit_version),
        tracks: tracks,
        globals: globals,
        tpqn: Map.get(data, :tpqn),
        time_sigs: time_sigs
      }
      |> Workspace.new()
    end
  end

  def load(other, %Registry{}), do: {:error, {:invalid_workspace_dump, other}}

  # ---- tracks ----

  defp dump_tracks(tracks, registry) when is_map(tracks) do
    Enum.reduce_while(tracks, {:ok, %{}}, fn {id, track}, {:ok, acc} ->
      case Track.dump(track, registry) do
        {:ok, dumped} -> {:cont, {:ok, Map.put(acc, id, dumped)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp load_tracks(tracks, registry) when is_map(tracks) do
    Enum.reduce_while(tracks, {:ok, %{}}, fn {id, dumped}, {:ok, acc} ->
      case Track.load(dumped, registry) do
        {:ok, track} -> {:cont, {:ok, Map.put(acc, id, track)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp load_tracks(other, _registry), do: {:error, {:invalid_tracks_dump, other}}

  defp load_globals(globals, registry) when is_map(globals),
    do: load_tracks(globals, registry)

  defp load_globals(other, _registry), do: {:error, {:invalid_globals_dump, other}}

  # ---- time_sigs：[{bar, {num, den}}] ↔ [%{bar: _, sig: %{num: _, den: _}}, ...] ----

  defp dump_time_sigs(time_sigs) do
    Enum.map(time_sigs, &TupleCodec.dump(&1, @time_sig))
  end

  defp load_time_sigs(time_sigs) when is_list(time_sigs) do
    time_sigs
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case TupleCodec.load(entry, @time_sig) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> then(fn
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end)
  end

  defp load_time_sigs(other), do: {:error, {:invalid_time_sigs_dump, other}}
end
