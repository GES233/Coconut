defmodule Coconut.Project do
  alias Coconut.Workspace
  alias Coconut.Util.ID

  @type t :: %__MODULE__{
          id: ID.t(),
          workspace: Workspace.t(),
          engine: term(),
          voicebank: term(),
          assets: term(),
          metadata: term()
        }

  defstruct [:id, :workspace, :engine, :voicebank, :assets, :metadata]
end
