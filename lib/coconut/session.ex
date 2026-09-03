defmodule Coconut.Session do
  @moduledoc """
  State carried by the `Coconut` facade.

  It is session-scoped: edit history and checked render rounds are never
  persisted in a `Coconut.Project`. The project metadata kept here excludes
  the workspace; `Coconut.project/1` always rebuilds a project from the
  history's current workspace.
  """

  alias Coconut.Edit.History
  alias Coconut.Project
  alias Coconut.Render.Engine

  @type project_metadata :: %{
          id: Coconut.Util.ID.t(Project.t()),
          voicebank: Project.voicebank() | nil,
          metadata: map() | nil
        }

  @type round :: %{request: Engine.Request.t(), checked: term()}

  @type t :: %__MODULE__{
          history: History.t(),
          project: project_metadata() | nil,
          channels: %{atom() => module()},
          engine: Engine.engine() | nil,
          interventions: map(),
          globals: map(),
          last_round: round() | nil
        }

  @enforce_keys [:history]
  defstruct history: nil,
            project: nil,
            channels: %{},
            engine: nil,
            interventions: %{},
            globals: %{},
            last_round: nil
end
