defmodule Coconut.Engine.Request do
  @moduledoc """
  Input bundle for one engine check/render round.

  Carries the workspace snapshot plus the folded interventions produced by
  `Coconut.Resolve.run_check/3`.
  """

  alias Coconut.Util.Object

  @type t :: %__MODULE__{
          workspace: Coconut.Workspace.t(),
          interventions: %{Coconut.Resolve.port_ref() => %{input: term()}}
        }

  use Object, keys: [:workspace, interventions: %{}]
end
