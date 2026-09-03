defmodule Coconut.Curve.ControlPoint do
  @moduledoc """
  A tick-based control point.
  """

  # --------------------------------------------------
  # tick: non_neg_integer  (absolute tick on the timeline)
  # value: float           (parameter value, e.g. cents, ratio)
  #
  # handle_left / handle_right are used by Bezier.
  # nil  -> auto (1/3 rule)
  # %{tick: integer(), value: float()}  -> offset from anchor
  #
  # --------------------------------------------------

  @typedoc "Bezier control handle"
  @type handle :: %{tick: integer(), value: float()}

  @type t :: %__MODULE__{
          tick: non_neg_integer(),
          value: float(),
          handle_left: handle() | nil,
          handle_right: handle() | nil
        }

  defstruct [:tick, :value, handle_left: nil, handle_right: nil]
end
