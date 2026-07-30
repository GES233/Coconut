defmodule Coconut.Workspace do
  @moduledoc """
  Aggregate for edit.
  """

  alias Coconut.Util.{ID, Model, Object}

  defmodule Side do
    @moduledoc """
    Contain raw data.
    """
    alias Coconut.Score.{TempoMap, Tick}

    @type span :: %{
            ID.t() => {start_tick :: Tick.numeric_tick(), end_tick :: Tick.numeric_tick()}
          }
    @type item :: term()

    @type t :: %__MODULE__{
            tempos_by_version: %{Tamale.version() => TempoMap.t()},
            spans_by_version: %{Tamale.version() => span()},
            elements_by_id: %{Tamale.id() => item()},
            patches: [Tamale.Patch.t()]
          }
    use Object, keys: [:tempos_by_version, :spans_by_version, :elements_by_id, :patches]
  end

  @type t :: %__MODULE__{
          id: ID.t(t()),
          edit_version: Tamale.version(),
          tempo_space: Tamale.Space.t() | nil,
          tracks: %{ID.t() => Tamale.Space.t()},
          side: Side.t()
        }
  use Model,
    keys: [:id, :edit_version, :tempo_space, :tracks, :side],
    id_prefix: "WSpc_"
end
