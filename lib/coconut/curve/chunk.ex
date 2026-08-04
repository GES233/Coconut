defmodule Coconut.Curve.Chunk do
  @moduledoc "A curve segment."
  # Adapter + container pattern: behaviour callbacks live on the adapter module.
  # container.points[].tick is an absolute tick on the timeline.
  # end_tick is computed on demand as adapter.span(container) and not stored.

  alias Coconut.Util.ID

  @type t :: %__MODULE__{
          id: ID.t(),
          adapter: module(),
          container: struct(),
          start_tick: non_neg_integer(),
          rasterized: term() | nil,
          extra: map()
        }
  defstruct [:id, :adapter, :container, :start_tick, rasterized: nil, extra: %{}]
end
