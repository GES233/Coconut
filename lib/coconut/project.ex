defmodule Coconut.Project do
  alias Coconut.Workspace
  alias Coconut.Util.{ID, Model}

  @type t :: %__MODULE__{
          id: ID.t(),
          workspace: Workspace.t(),
          engine: term(),
          voicebank: term(),
          assets: term(),
          metadata: term()
        }
  use Model,
    keys: [
      :id,
      :workspace,
      :engine,
      :voicebank,
      :assets,
      :metadata
    ],
    id_prefix: "Prj_"
end
