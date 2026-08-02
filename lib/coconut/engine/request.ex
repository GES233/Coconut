defmodule Coconut.Engine.Request do
  @moduledoc """
  Input bundle for one engine check/render round.

  Carries the workspace snapshot plus the folded interventions produced by
  `Coconut.Resolve.run_check/3`.

  `globals` holds engine-level knobs not anchored to any note (gender,
  depth, quality steps, ...). They bypass the patch/digest/transport axis
  entirely — there is no position to anchor — but they still pass the
  `Coconut.Engine.run_check/2` gate, which validates them against the
  engine's declared `:globals` spec before `check/2` is consulted.
  """

  alias Coconut.Util.Object

  @type t :: %__MODULE__{
          workspace: Coconut.Workspace.t(),
          interventions: %{Coconut.Resolve.port_ref() => %{input: term()}},
          globals: %{atom() => term()}
        }

  use Object, keys: [:workspace, interventions: %{}, globals: %{}]
end
