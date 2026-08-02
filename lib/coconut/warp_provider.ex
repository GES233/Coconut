defmodule Coconut.WarpProvider do
  @moduledoc """
  Constructs `Tamale.Warp` segments for Coconut coordinate systems.

  ## v1: non-ripple tick-space

  Global tick coordinates do NOT change when notes are retimed or
  deleted. All transport in `:tick` space is identity. Content changes
  are the responsibility of `Patch.resolve`, not warp.

  | op                   | global `:tick` warp |
  |----------------------|---------------------|
  | Retime / Delete / …  | identity            |
  | Insert / Move / …    | identity            |

  ## Caveats

  - WarpProvider is a thin factory now. Ripple mode (v2) and
    frame-space warp will add non-identity logic.
  - The closure returns `Tamale.Warp.t()` directly (no error tuple), so the
    coord must be guarded before invoking: `Coconut.Patch.new/1` rejects
    Metric anchors outside `supported_coords/0` at construction time.
  """

  alias Tamale.Warp

  @doc """
  Returns a `warp_provider` closure for the `:tick` coordinate system.

  In v1 non-ripple, all ops produce identity warp.
  `track_spans` is accepted but unused (kept for v2 API compatibility).
  """
  @spec tick(map()) :: Tamale.Transport.warp_provider()
  def tick(_track_spans) do
    fn :tick, _entry -> Warp.identity() end
  end

  @doc """
  Coordinate systems this provider can serve.

  `Coconut.Patch.new/1` rejects Metric anchors outside this list at
  construction time — that guard is what keeps the single-clause `tick/1`
  closure total in practice.
  """
  @spec supported_coords() :: [atom()]
  def supported_coords, do: [:tick]
end
