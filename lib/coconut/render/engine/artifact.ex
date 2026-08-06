defmodule Coconut.Render.Engine.Artifact do
  @moduledoc """
  The render product's formal shape (design doc §11.1).

  `payload` is engine-specific: file paths and frame counts today,
  in-memory audio buffers once render stops touching disk. Generic fields
  travel beside it: the request's globals and folded overrides (echoed so
  callers can correlate), the engine's display name, and the edit version
  the artifact was rendered from — the §11.5 version pin.
  """

  @type t :: %__MODULE__{
          engine: String.t(),
          edit_version: Tamale.version(),
          payload: term(),
          globals: %{atom() => term()},
          overrides: %{Coconut.Render.Resolve.port_ref() => %{input: term()}}
        }

  defstruct [:engine, :edit_version, :payload, globals: %{}, overrides: %{}]
end
