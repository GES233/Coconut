defmodule Coconut.Score.Note do
  @moduledoc """
  Domain models and structures related to musical notes.

  A Note is a pure content carrier (design doc §11.2, settled 2026-08-03):
  it holds pitch/lyric/metadata and **no timing**. Timing lives in the
  track's spans table, which remains the single timing authority across
  transport — there is no snapshot to drift out of sync.
  """
  alias Coconut.{Score.Key, Util.ID}

  import Coconut.Util.Helpers, only: [normalize_attrs: 2, strictly_normalize_attrs: 2]

  @typedoc """
  metadata is scope => inner.

  It must be serializable.

  maps, lists, strings, numbers, nil, etc.
  """
  @type metadata :: %{binary() => term()}

  @keys [
    :id,
    :key,
    :lyric,
    annotation: nil,
    metadata: %{}
  ]
  defstruct @keys

  @type note_id :: ID.t(__MODULE__)

  @type t :: %__MODULE__{
          id: note_id(),
          key: Key.t(),
          lyric: String.t() | nil,
          annotation: String.t() | nil,
          metadata: metadata()
        }

  # ---- Constructor ----

  @doc """
  Cast a raw element map into a Note ("Map → Note").

  `attrs` recognises `:pitch` (a number, cast to `Key.TwelveET`, or an
  existing `Score.Key` struct), `:lyric` and `:annotation`; every other
  key is carried in `metadata` with stringified keys.

  Timing is *not* accepted here: the span is recorded in the track's spans
  table by the lowering layer, never on the Note.

  ## Examples

      iex> from_element("n1", %{pitch: 60, lyric: "ら", phonemes: [["r", "a"]]})
      {:ok, %Note{id: "n1", lyric: "ら", metadata: %{"phonemes" => [["r", "a"]]}}}
  """
  @spec from_element(Tamale.id(), map()) :: {:ok, t()} | {:error, term()}
  def from_element(id, attrs) do
    {pitch, attrs} = Map.pop(attrs, :pitch)
    {lyric, attrs} = Map.pop(attrs, :lyric)
    {annotation, attrs} = Map.pop(attrs, :annotation)

    with {:ok, key} <- cast_key(pitch) do
      new(%{
        id: id,
        key: key,
        lyric: lyric,
        annotation: annotation,
        metadata: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
      })
    end
  end

  # Key-system note (settled 2026-08): the numeric cast is hardwired to
  # TwelveET, and the struct clause passes ANY struct through unchecked —
  # both deliberate placeholders until a second `Coconut.Score.Key`
  # implementation lands. Revisit then rather than building on the current
  # shape (the Key protocol itself may change with the new arrival):
  # tighten the passthrough to Key.Inner-implementing structs, and take
  # the tuning module from the track/project context.
  defp cast_key(nil), do: {:ok, nil}
  defp cast_key(%_{} = key), do: {:ok, key}
  defp cast_key(n) when is_number(n), do: Key.TwelveET.from_midi(n, nil)
  defp cast_key(other), do: {:error, {:invalid_key, other}}

  @doc """
  Canonical projection for digests (`Tamale.Digest` rejects structs).

  Key 的 canonical 形式由所属 `Coconut.Score.Key` adapter 提供。整数
  十二平均律保持 `%{midi: integer}`；微分音 adapter 可用整数分数或音律
  步级表达，Note 不假设 MIDI，也不让 float 进入 Tamale digest。
  """
  @spec to_canonical(t()) :: map()
  def to_canonical(%__MODULE__{} = note) do
    note
    |> Map.from_struct()
    # key is some *struct* implements `Coconut.Score.Key` or nil(e.g. Rap).
    |> Map.update!(:key, fn
      nil -> nil
      %_{} = key -> Key.to_canonical(key)
    end)
  end

  @doc """
  Create new note.

  Note identity is by `id`. Ordering is extrinsic to the Note struct.

  ## Examples

      iex> new(%{id: "Note_12345"})
      {:ok, %Note{id: "Note_12345"}}

      iex> new(%{})
      {:error, {:missing_id, "Note_"}}
  """
  def new(attrs) do
    with {:ok, normalized} <- normalize_attrs(attrs, @keys) do
      case Map.fetch(normalized, :id) do
        :error ->
          {:error, {:missing_id, "Note_"}}

        {:ok, _id} ->
          normalized
          |> then(&struct!(%__MODULE__{}, &1))
          |> validate()
      end
    end
  end

  @doc "Modify the properties of an existing note (modifying the id is not allowed)."
  @spec update(t(), map() | keyword()) :: {:ok, t()} | {:error, term()}
  def update(note, attrs) do
    with {:ok, normalized} <- strictly_normalize_attrs(attrs, @keys),
         :ok <- if(Map.has_key?(normalized, :id), do: {:error, :id_immutable}, else: :ok) do
      new_note = struct(note, normalized)
      validate(new_note)
    end
  end

  # ---- Validator ----

  @doc """
  Validates a note.

  The following are invalid:

  * `lyric` is neither `nil` nor a string
  """
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{lyric: lyric}) when not (is_nil(lyric) or is_binary(lyric)),
    do: {:error, {:lyric_not_support, lyric}}

  def validate(model), do: {:ok, model}

  # ---- Business functions ----

  @doc """
  Drags a note to a new key.

  Only modifies the note itself; timing moves are span-table business
  (see the `Coconut.Edit.Operations.DragNote` request).

  ## Options

  Accepts a map or keyword list. Only the following keys are recognised:

  - `:key` — new pitch
  """
  @spec drag_note(t(), %{optional(:key) => Key.t()} | keyword(Key.t())) ::
          {:ok, t()} | {:error, term()}
  def drag_note(note, new_key) do
    {new_key, rest} = new_key |> Map.new() |> Map.pop(:key, note.key)

    case map_size(rest) do
      0 -> update(note, key: new_key)
      _num -> {:error, {:extra_fields_exist, rest}}
    end
  end

  @doc "Update note's lyric."
  @spec update_lyric(t(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def update_lyric(note, new_lyric) do
    update(note, lyric: new_lyric)
  end

  @doc """
  Updates the note's annotation.

  Annotations are UI-only; the engine and plugins do not read them.
  """
  @spec update_annotation(t(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def update_annotation(note, new_annotation) do
    case new_annotation do
      nil -> update(note, annotation: nil)
      new_annotation when is_binary(new_annotation) -> update(note, annotation: new_annotation)
      _ -> {:error, :annotation_not_support}
    end
  end

  # ---- Metadata Edit.Operations ----

  @doc "Merges new metadata into the note's current metadata."
  @spec update_metadata(t(), map()) :: {:ok, t()} | {:error, term()}
  def update_metadata(note, new_metadata) when is_map(new_metadata) do
    update(note, metadata: Map.merge(note.metadata, new_metadata))
  end

  @doc """
  Fetches metadata.

  * `get_metadata/1` returns all metadata.
  * `get_metadata/2` returns `{:error, {:key_not_found, key}}` when the key is absent.
  """
  @spec get_metadata(t()) :: {:ok, metadata()}
  def get_metadata(note), do: {:ok, note.metadata}

  # Uses Map.fetch/2 to distinguish between a nil value and a missing key.
  @spec get_metadata(t(), key :: binary()) ::
          {:ok, term()} | {:error, {:key_not_found, key :: binary()}}
  def get_metadata(note, key) when is_binary(key) do
    case Map.fetch(note.metadata, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:key_not_found, key}}
    end
  end

  @doc """
  Removes metadata.

  Typically used at the end of a plugin lifecycle or before serialization.
  """
  @spec remove_metadata(t(), :all | [binary()]) :: {:ok, t()}
  def remove_metadata(note, :all), do: update(note, metadata: %{})

  def remove_metadata(note, keys) when is_list(keys),
    do: update(note, metadata: Map.drop(note.metadata, keys))
end
