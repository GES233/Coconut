defmodule Coconut.Score.Key do
  @moduledoc """
  Domain model for pitch.

  Uses an adapter pattern to support different tuning systems. The motivation
  for pluggability is future non-12ET systems or microtonality: each
  Key module owns its exact, digest-safe canonical form, so the kernel never
  presupposes MIDI (see docs/design-2026-08-orchid-intervention.md §6.4).

  每个 adapter 同时拥有三类边界：

  * `to_canonical/1`：进入 Tamale digest 的精确、无 float 表示；
  * `dump/1` / `load/1`：Key 自身的 Pickle 载荷；
  * `Inner` protocol：面向乐谱显示或引擎的 MIDI / Hz 换算，允许 float。

  微分音 adapter 应在前两类边界使用整数分子/分母、音律步级或规范化
  十进制字符串；只有送往声学引擎时才转换为 float。这样增加新音律无需
  修改 `Coconut.Score.Note`、Pickle 或 Tamale。
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

  @doc "返回供 Tamale digest 使用的精确 plain term；不得包含 float 或 struct。"
  @callback to_canonical(key_struct()) :: term()

  @doc "把 Key 摊平为不含 module 标签的 Pickle map。"
  @callback dump(key_struct()) :: {:ok, map()} | {:error, term()}

  @doc "从 adapter 自己的 Pickle map 重建 Key。"
  @callback load(map()) :: {:ok, key_struct()} | {:error, term()}

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

  def to_canonical(%module{} = key), do: module.to_canonical(key)

  def dump(%module{} = key), do: module.dump(key)

  def load(data, module) when is_atom(module), do: module.load(data)

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
