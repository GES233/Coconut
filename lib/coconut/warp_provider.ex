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
  - The closure returns `Tamale.Warp.t()` directly (no error tuple).
    Callers for non-:tick coords should guard before invoking.
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
end
