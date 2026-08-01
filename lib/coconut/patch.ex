defmodule Coconut.Patch do
  @moduledoc """
  A user edit bound to an anchor: `(anchor, tamale_patch)`.

  The anchor identifies *where* the edit applies (an element, a time interval,
  etc.); the tamale patch carries the semantic survival check (`base_digest`,
  `payload`). Transport moves the anchor; digest resolution judges the patch.

  `channel` groups patches for `Coconut.Resolve` — each channel supplies its
  own digest projection and fold target.
  """

  alias Coconut.Util.Object

  @type t :: %__MODULE__{
          track_id: Coconut.Operate.track_id(),
          anchor: Tamale.Anchor.t(),
          patch: Tamale.Patch.t(),
          channel: atom()
        }

  use Object, keys: [:track_id, :anchor, :patch, channel: :default]
end
