defmodule Coconut.WarpProvider do
  @moduledoc """
  Constructs `Tamale.Warp` segments from op log entries + span snapshots.

  The design doc (Section 5) defines the warp_provider as a closure that
  captures a per-track spans table and returns a `(coord, entry) -> Warp.t()`
  callback for `Tamale.Transport.transport/3`.

  ## v1: tick-space, non-ripple, total warp

  The warp is a **total map**: Retime produces a linear segment, and all
  uncovered intervals pass through as identity. Coordinates outside a
  Retimed region survive at the same position.

  | op                   | warp          | ingredient        |
  |----------------------|---------------|-------------------|
  | Retime(id, old, new) | {old, new}    | op self-contained |
  | Delete / Insert / …  | identity      | —                 |

  ## Caveats

  - Non-ripple means stretching a note does not kill edits on other notes.
    Metric anchors at untouched coordinates survive unchanged.
  - Frame-space warp (v2) will compose tick to sec to frame via TempoMap.
  """

  alias Tamale.Op.{Delete, Retime}
  alias Tamale.Warp

  @doc """
  Returns a `warp_provider` closure for the `:tick` coordinate system.

  `track_spans` is a per-track `%{version => %{id => {start, end}}}` —
  obtain it from `Workspace.track_spans/2`.
  """
  @spec tick(track_spans :: %{Tamale.version() => %{Tamale.id() => {non_neg_integer(), non_neg_integer()}}}) ::
          Tamale.Transport.warp_provider()
  def tick(track_spans) do
    fn
      :tick, {version, ops} -> build_warp(ops, version, track_spans)
      _coord, _entry -> {:error, :unsupported_coord}
    end
  end

  defp build_warp([], _version, _spans), do: Warp.identity()

  defp build_warp(ops, version, spans) do
    pre_spans = Map.get(spans, version - 1, %{})
    segments = Enum.flat_map(ops, &op_segments(&1, pre_spans))

    case segments do
      [] -> Warp.identity()
      segs ->
        case Warp.from_segments(segs) do
          {:ok, warp} -> Warp.total(warp)
          {:error, _} = err -> err
        end
    end
  end

  # Retime is self-contained.
  defp op_segments(%Retime{old_span: {os, oe}, new_span: {ns, ne}}, _pre_spans) do
    [{{os, oe}, {ns, ne}}]
  end

  # Delete / Insert / Move / Split / Merge — identity in non-ripple.
  defp op_segments(%Delete{}, _pre_spans), do: []
  defp op_segments(_op, _pre_spans), do: []
end
