defmodule Coconut.Score.Key do
  @moduledoc """
  Domain model for pitch.

  Uses an adapter pattern to support different tuning systems.

  Handles conversion between two representations:

  * Staff notation data
  * MIDI / frequency data

  Key values are stored and serialized in their internal type.
  """

  @type key_struct :: struct()

  @type t :: key_struct()

  # ---- Basic CRUD ----

  # Create
  @callback new(any()) :: {:ok, key_struct()} | {:error, term()}

  # No default implementations are provided; each tuning system must implement
  # `new/1` and `from_midi/2`.
  @callback from_score(score_data :: term(), type :: atom(), ctx :: term()) ::
              {:ok, key_struct()} | {:error, term()}

  @callback from_midi(midi_note :: number(), ctx :: term()) ::
              {:ok, key_struct()} | {:error, term()}

  # Outbound
  defprotocol Inner do
    @moduledoc "Outbound conversion operations."

    # ---- Staff Notation ----

    @doc "Converts to staff notation data for the given staff type (e.g., `:staff`, `:numbered`)."
    def to_score(key, type, ctx)
    # e.g. converting a 12-TET piano roll to five-line staff requires a key signature as context.

    # ---- MIDI / Frequency ----

    @doc "Converts to a MIDI note number (float allowed)."
    def to_midi(key)

    @doc "Converts to frequency in Hz."
    def to_frequency(key, reference)
  end

  # ---- Facade API ----

  def new(attrs, module), do: module.new(attrs)

  def from_score(data, type, ctx, module), do: module.from_score(data, type, ctx)

  def from_midi(midi, ctx, module), do: module.from_midi(midi, ctx)

  defdelegate to_score(key, type, ctx), to: Inner

  defdelegate to_midi(key), to: Inner

  defdelegate to_frequency(key, reference), to: Inner

  defmacro __using__(_opts) do
    quote do
      @behaviour Coconut.Score.Key
      alias Coconut.Score.Key.Inner

      @impl true
      def from_score(_score_data, _type, _ctx), do: {:error, :not_implemented}

      @impl true
      def from_midi(_midi, _ctx), do: {:error, :not_implemented}

      defoverridable from_score: 3, from_midi: 2
    end
  end
end
