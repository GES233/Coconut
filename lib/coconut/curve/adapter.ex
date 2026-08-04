defmodule Coconut.Curve.Adapter do
  @moduledoc """
  Implement your own curve adapter.

  ## Example

      defmodule Foo do
        # Adapter-specific fields go here.
        use Coconut.Curve.Adapter, keys: ...

        @impl Coconut.Curve.Adapter
        def control_points(foo), do: ...
        @impl Coconut.Curve.Adapter
        def span(foo), do: ...
        @impl Coconut.Curve.Adapter
        def rasterize(foo, tick_seq), do: ...
      end

  ## Implementing Rasterization

  The main purpose here is to sample a parameter curve at the ticks provided by `tick_seq`
  (derived from Tempo), using those ticks as the rasterization units.

  This is also why `c:Coconut.Curve.Adapter.span/1` matters: it lets callers request only a
  sub-range of the curve for serialization.

  The name "rasterize" is carried over because the downstream engine generally expects data
  rasterized in physical time.
  """

  alias Coconut.Curve.ControlPoint

  # ---- Domain helper functions would go here ----

  @doc "Returns the list of control points inside the container, in ticks."
  @callback control_points(container :: struct()) :: [ControlPoint.t()]

  @doc "Returns the curve's time span (the absolute tick of the last control point). Empty curves return 0."
  @callback span(container :: struct()) :: non_neg_integer()

  @doc "Samples the curve at the given tick sequence and returns a `float-32-native` binary. `tick_seq` may be a list or `Range`."
  @callback rasterize(
              container :: struct(),
              tick_seq :: Enumerable.t(Coconut.Score.Tick.numeric_tick())
            ) ::
              binary()
  # Replaceable with a NIF later.

  defmacro __using__(opts) do
    keys = Keyword.fetch!(opts, :keys)

    quote do
      defstruct unquote(keys)
      @behaviour Coconut.Curve.Adapter
      alias Coconut.Curve.ControlPoint
    end
  end
end
