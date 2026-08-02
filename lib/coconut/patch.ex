defmodule Coconut.Patch do
  @moduledoc """
  A user edit bound to an anchor: `(anchor, tamale_patch)`.

  The anchor identifies *where* the edit applies (an element, a time interval,
  etc.); the tamale patch carries the semantic survival check (`base_digest`,
  `payload`). Transport moves the anchor; digest resolution judges the patch.

  `channel` groups patches for `Coconut.Resolve` — each channel supplies its
  own digest projection and fold target.

  `new/1` enforces construction-time legality: a Metric anchor whose `coord`
  the warp provider cannot serve (v1: only `:tick`) is rejected with
  `{:error, {:unsupported_coord, coord}}` instead of crashing `Resolve` later.
  """

  alias Coconut.{Util.Object, WarpProvider}

  @type t :: %__MODULE__{
          track_id: Coconut.Operate.track_id(),
          anchor: Tamale.Anchor.t(),
          patch: Tamale.Patch.t(),
          channel: atom()
        }

  use Object, keys: [:track_id, :anchor, :patch, channel: :default]

  @doc """
  Construction-time legality: a Metric anchor must name a coordinate system
  the warp provider can serve (v1: `:tick` only).

  Without this guard an unsupported `coord` mounts fine and crashes
  `Coconut.Resolve.run_check/3` later: tamale folds the op log and calls
  `warp_provider.(coord, entry)`, where the single-clause provider closure
  has no match (`FunctionClauseError`).
  """
  @impl true
  def validate(%__MODULE__{anchor: %Tamale.Anchor.Metric{coord: coord}} = obj) do
    if coord in WarpProvider.supported_coords() do
      {:ok, obj}
    else
      {:error, {:unsupported_coord, coord}}
    end
  end

  def validate(obj), do: {:ok, obj}
end
