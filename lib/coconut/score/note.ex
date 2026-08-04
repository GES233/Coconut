defmodule Coconut.Score.Note do
  @moduledoc """
  Domain models and structures related to musical notes.

  A Note is a pure content carrier (design doc §11.2, settled 2026-08-03):
  it holds pitch/lyric/metadata and **no timing**. Timing lives in the
  track's spans table, which remains the single timing authority across
  transport — there is no snapshot to drift out of sync.
  """
  alias Coconut.{Util.ID, Score.Key}
  alias Coconut.Score.Tick

  import Coconut.Helpers, only: [normalize_attrs: 2, strictly_normalize_attrs: 2]

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

  @typedoc "A tick span `{start, end}` from the track's spans table."
  @type span :: {Tick.numeric_tick(), Tick.numeric_tick()}

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

      iex> from_element("n1", %{pitch: 60, lyric: "ら", phonemes: [["zh", "a"]]})
      {:ok, %Note{id: "n1", lyric: "ら", metadata: %{"phonemes" => [["zh", "a"]]}}}
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

  defp cast_key(nil), do: {:ok, nil}
  defp cast_key(%_{} = key), do: {:ok, key}
  defp cast_key(n) when is_number(n), do: Key.TwelveET.from_midi(n, nil)
  defp cast_key(other), do: {:error, {:invalid_key, other}}

  @doc """
  Canonical projection for digests (`Tamale.Digest` rejects structs).

  The key struct is reduced to a plain map (`Map.from_struct/1`); every
  remaining field is already canonical.
  """
  @spec to_canonical(t()) :: map()
  def to_canonical(%__MODULE__{} = note) do
    note
    |> Map.from_struct()
    # key is some *struct* implements `Coconut.Score.Key` or nil(e.g. Rap).
    |> Map.update!(:key, fn
      nil -> nil
      %_{} = key -> Map.from_struct(key)
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
         :ok <- if(Map.has_key?(normalized, :id), do: {:error, :id_immutable}, else: :ok),
         new_note = struct(note, normalized) do
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
  (see the `Coconut.Operations.DragNote` request).

  ## Options

  Accepts a map or keyword list. Only the following keys are recognised:

  - `:key` — new pitch
  """
  @spec drag_note(t(), %{optional(:key) => Key.t()} | keyword(Key.t())) ::
          {:ok, t()} | {:error, term()}
  def drag_note(note, new_key) do
    {new_key, rest} = new_key |> Map.new() |> Map.pop(:key, note.key)

    with 0 <- map_size(rest) do
      update(note, key: new_key)
    else
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

  # ---- Metadata Operations ----

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

  # ---- Split and Merge Note ----

  @doc """
  Splits a note's content at an absolute tick position.

  The span is injected by the caller (the track's spans table is the timing
  authority); `split_tick` must fall strictly inside it
  (`start < split_tick < end`).

  Returns `{:ok, note_before, note_after}`. Content is timing-free, so
  `note_before` is the note itself; `note_after` gets `new_id` plus the
  parent's content, overridable via `attrs` (e.g. a different lyric).
  """
  @spec split(t(), span(), Tick.numeric_tick(), ID.t(t()), map() | keyword()) ::
          {:ok, t(), t()} | {:error, term()}
  def split(note, {start_tick, end_tick}, split_tick, new_id, attrs \\ []) do
    cond do
      split_tick <= start_tick ->
        {:error, {:split_tick_before_note, split_tick, start_tick}}

      split_tick >= end_tick ->
        {:error, {:split_tick_after_note, split_tick, end_tick}}

      true ->
        extra_attrs =
          attrs
          |> Enum.into(%{})
          |> Map.take([:key, :lyric, :annotation, :metadata])

        after_attrs =
          Map.merge(
            %{
              id: new_id,
              key: note.key,
              lyric: note.lyric,
              annotation: note.annotation,
              metadata: note.metadata
            },
            extra_attrs
          )

        case new(after_attrs) do
          {:ok, after_note} -> {:ok, note, after_note}
          {:error, _} = err -> err
        end
    end
  end

  @doc """
  Merges two notes' content into one.

  Spans are injected by the caller (same authority argument as `split/5`)
  and used only for the gap check. `merged_id` is injected by the caller —
  Note does not generate IDs.

  ## Options

  - `:gap_tolerance` — maximum allowed gap between the two spans in ticks (default 0: must be adjacent or overlapping)
  - `:lyric_merger` — pluggable lyric concatenation function (`({Note.t(), Note.t()} -> {:ok, term()} | {:error, term()})`); defaults to concatenating when both are non-nil
  - `:annotation_merger` — pluggable annotation merge function (`({Note.t(), Note.t()} -> {:ok, term()} | {:error, term()})`); defaults to the first non-nil value

  ## Behaviour

  - Both notes must share the same pitch (compared via `Key.to_midi/1`)
  - Spans must overlap, or the gap ≤ `gap_tolerance`
  - Returns `{:ok, merged_note}` with the given `merged_id`
  - Merged annotation takes the first non-nil value
  """
  @spec merge(t(), span(), t(), span(), ID.t(t()), keyword()) :: {:ok, t()} | {:error, term()}
  def merge(note1, {s1, e1}, note2, {s2, e2}, merged_id, opts \\ []) do
    gap_tolerance = Keyword.get(opts, :gap_tolerance, 0)

    lyric_merger =
      Keyword.get(opts, :lyric_merger, fn note1, note2 ->
        {:ok,
         cond do
           is_nil(note1.lyric) and is_nil(note2.lyric) -> nil
           is_nil(note1.lyric) -> note2.lyric
           is_nil(note2.lyric) -> note1.lyric
           note1.lyric == note2.lyric -> note1.lyric
           true -> note1.lyric <> note2.lyric
         end}
      end)

    annotation_merger =
      Keyword.get(opts, :annotation_merger, fn note1, note2 ->
        {:ok, note1.annotation || note2.annotation}
      end)

    cond do
      Key.to_midi(note1.key) != Key.to_midi(note2.key) ->
        {:error, {:key_mismatch, Key.to_midi(note1.key), Key.to_midi(note2.key)}}

      e1 + gap_tolerance < s2 or e2 + gap_tolerance < s1 ->
        {:error, {:gap_too_large, e1, s2, gap_tolerance}}

      true ->
        do_merge(note1, note2, merged_id, lyric_merger, annotation_merger)
    end
  end

  # ---- Toolkit functions ----

  # Execute merge
  defp do_merge(note1, note2, merged_id, lyric_merger, annotation_merger) do
    with {:ok, lyric} <- lyric_merger.(note1, note2),
         {:ok, annotation} <- annotation_merger.(note1, note2) do
      %{
        id: merged_id,
        key: note1.key,
        lyric: lyric,
        annotation: annotation,
        metadata: Map.merge(note1.metadata, note2.metadata)
      }
      |> new()
    end
  end
end
