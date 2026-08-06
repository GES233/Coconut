defmodule Coconut.Pickle.Workspace do
  @moduledoc """
  `Coconut.Edit.Workspace` 的原生对象 codec（arity-2：`dump/2` / `load/2`）。

  与 `Coconut.Pickle.Track` 一样不实现 `Coconut.Pickle` behaviour——
  需要注入 registry 的 codec 用 arity-2 同风格签名。

  dump 为摊平的 map：

  - `id` / `edit_version` / `tpqn` 原样直出；
  - `tracks` map 的键（track id）直出，每个 value 走
    `Coconut.Pickle.Track` codec；`tempo` 轨同走 Track codec；
  - `time_sigs` 是 `[{bar, {num, den}}]`，dump 为
    `[[bar, [num, den]], ...]`，load 反向还原为 tuple。

  load 还原后经 `Coconut.Edit.Workspace.new/1` 重建——`validate/1` 自然生效：
  tempo 轨能力、tempo id 冲突、time_sigs 合法性都会被复检。
  """

  alias Coconut.Pickle.{Registry, Track}
  alias Coconut.Edit.Workspace

  @doc "把 `Coconut.Edit.Workspace` 摊平为仅含允许类型的 plain map。"
  @spec dump(Workspace.t(), Registry.t()) :: {:ok, map()} | {:error, term()}
  def dump(%Workspace{} = ws, %Registry{} = registry) do
    with {:ok, tracks} <- dump_tracks(ws.tracks, registry),
         {:ok, tempo} <- Track.dump(ws.tempo, registry) do
      {:ok,
       %{
         id: ws.id,
         edit_version: ws.edit_version,
         tracks: tracks,
         tempo: tempo,
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
         {:ok, tempo} <- load_tempo(Map.get(data, :tempo), registry),
         {:ok, time_sigs} <- load_time_sigs(Map.get(data, :time_sigs)) do
      %{
        id: Map.get(data, :id),
        edit_version: Map.get(data, :edit_version),
        tracks: tracks,
        tempo: tempo,
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

  defp load_tempo(%{} = dumped, registry), do: Track.load(dumped, registry)
  defp load_tempo(other, _registry), do: {:error, {:invalid_tempo_dump, other}}

  # ---- time_sigs：[{bar, {num, den}}] ↔ [[bar, [num, den]], ...] ----

  defp dump_time_sigs(time_sigs) do
    Enum.map(time_sigs, fn {bar, {num, den}} -> [bar, [num, den]] end)
  end

  defp load_time_sigs(time_sigs) when is_list(time_sigs) do
    Enum.reduce_while(time_sigs, {:ok, []}, fn entry, {:ok, acc} ->
      case entry do
        [bar, [num, den]]
        when is_integer(bar) and is_integer(num) and is_integer(den) ->
          {:cont, {:ok, [{bar, {num, den}} | acc]}}

        other ->
          {:halt, {:error, {:invalid_time_sig_dump, other}}}
      end
    end)
    |> then(fn
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end)
  end

  defp load_time_sigs(other), do: {:error, {:invalid_time_sigs_dump, other}}
end
