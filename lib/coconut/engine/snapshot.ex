defmodule Coconut.Engine.Snapshot do
  # Ensure how fields.
  @type t :: %__MODULE__{
    tracks: term(),
    tempo_map: term(),
    edit_version: Tamale.version(),
    tpqn: Coconut.Score.TimeSig.tpqn()
  }
  use Coconut.Util.Object, keys: [:tracks, :tempo_map, :edit_version, :tpqn]
end
