defmodule Coconut.Engine.Snapshot do
  @moduledoc """
  The flattened score view for one engine check/render round (design doc §11.1).

  Engines never see `Coconut.Workspace` — they read this value snapshot:
  per-track flattened views (each track module's `view/1`), the compiled
  `TempoMap`, and the workspace's `edit_version` pin. The pin is how a
  stale `checked` bundle is detected once the workspace has moved on
  (design doc §11.5; enforcement lands with the server shell).
  """

  alias Coconut.{Workspace, Track}

  @typedoc """
  Per-track flattened view: the track module, its coordinate domain, and
  its `[{id, element, span}]` elements (see `Coconut.Track.view/1`).
  """
  @type track_view :: %{
          module: module(),
          coord: :tick | :frame,
          elements: Coconut.Track.view()
        }

  @type t :: %__MODULE__{
          tracks: %{Coconut.Track.track_id() => track_view()},
          tempo_map: Coconut.Score.TempoMap.t() | nil,
          edit_version: Tamale.version(),
          tpqn: pos_integer()
        }

  defstruct [:tracks, :tempo_map, :edit_version, tpqn: 480]

  @doc """
  Flatten a workspace into an engine-facing snapshot.

  `tempo_map` is `nil` when the tempo track has no events — engines
  apply their own fallback (DiffSinger: flat 120 BPM). An uncompilable
  tempo track is an `{:error, _}`.
  """
  @spec from_workspace(Workspace.t()) :: {:ok, t()} | {:error, term()}
  def from_workspace(%Workspace{} = ws) do
    tracks =
      Map.new(ws.tracks, fn {track_id, track} ->
        {track_id,
         %{
           module: track.module,
           coord: Track.coord_domain(track),
           elements: Track.view(track)
         }}
      end)

    case Workspace.tempo_map(ws) do
      {:ok, tempo_map} ->
        {:ok, tempo_map}

      {:error, :no_tempo_track} ->
        {:ok, nil}

      {:error, _} = error ->
        error
    end
    |> case do
      {:ok, tempo_map} ->
        {:ok, %__MODULE__{
          tracks: tracks,
          tempo_map: tempo_map,
          edit_version: ws.edit_version,
          tpqn: ws.tpqn
        }}

      {:error, _} = error ->
        error
    end
  end
end
