defmodule Coconut.Score.Key.TwelveET do
  @moduledoc """
  12-tone equal temperament pitch adapter.

  Stores the pitch as a MIDI note number. `new/1` accepts any number; `to_midi/1`
  returns a float.
  """

  use Coconut.Score.Key

  defstruct [:midi]

  # ---- Key behaviour ----

  @impl true
  def new(midi) when is_number(midi), do: {:ok, %__MODULE__{midi: midi}}

  @impl true
  def from_midi(midi, _ctx), do: new(midi)

  # ---- Inner protocol implementation ----

  defimpl Inner, for: __MODULE__ do
    def to_midi(%{midi: midi}), do: midi * 1.0

    def to_frequency(%{midi: midi}, reference), do: reference * :math.pow(2, (midi - 69) / 12)

    def to_score(_key, _type, _ctx), do: {:error, :not_implemented}
  end
end
