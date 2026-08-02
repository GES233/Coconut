defmodule Coconut.Score.Note do
  @moduledoc """
  Domain models and structures related to musical notes.
  """
  alias Coconut.{Util.ID, Util.Model, Score.Key}
  alias Coconut.Score.Tick

  @typedoc """
  metadata is scope => inner.

  It must be serializable.

  maps, lists, strings, numbers, nil, etc.
  """
  @type metadata :: %{binary() => term()}

  use Model,
    keys: [
      :id,
      :start_tick,
      :duration_tick,
      :key,
      :lyric,
      annotation: nil,
      metadata: %{}
    ],
    id_prefix: "Note_"

  @type t :: %__MODULE__{
          id: ID.t(),
          start_tick: Tick.t(),
          duration_tick: Tick.t(),
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

  `start_tick` / `duration_tick` snapshot the insert span — the workspace
  spans table remains the timing authority after transport.

  ## Examples

      iex> from_element("n1", {0, 480}, %{pitch: 60, lyric: "ら", phonemes: [["zh", "a"]]})
      {:ok, %Note{id: "n1", start_tick: 0, duration_tick: 480, lyric: "ら",
                  metadata: %{"phonemes" => [["zh", "a"]]}}}
  """
  @spec from_element(Tamale.id(), {non_neg_integer(), non_neg_integer()}, map()) ::
          {:ok, t()} | {:error, term()}
  def from_element(id, {start_tick, end_tick}, attrs) do
    {pitch, attrs} = Map.pop(attrs, :pitch)
    {lyric, attrs} = Map.pop(attrs, :lyric)
    {annotation, attrs} = Map.pop(attrs, :annotation)

    with {:ok, key} <- cast_key(pitch) do
      new(%{
        id: id,
        start_tick: start_tick,
        duration_tick: end_tick - start_tick,
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

  # ---- Validator ----

  @doc """
  Validates a note.

  The following are invalid:

  * `start_tick` or `duration_tick` is negative
  * `lyric` is neither `nil` nor a string
  """
  @impl true
  def validate(%__MODULE__{start_tick: start_tick}) when start_tick < 0,
    do: {:error, {:invalid_negative_tick, start_tick}}

  def validate(%__MODULE__{duration_tick: duration_tick}) when duration_tick < 0,
    do: {:error, {:invalid_negative_tick, duration_tick}}

  def validate(%__MODULE__{lyric: lyric}) when not (is_nil(lyric) or is_binary(lyric)),
    do: {:error, {:lyric_not_support, lyric}}

  def validate(model), do: {:ok, model}

  # ---- Business functions ----

  @doc """
  Drags a note to a new key and/or start tick.

  Only modifies the note itself; overlap constraints are enforced downstream.

  ## Options

  Accepts a map or keyword list. Only the following keys are recognised:

  - `:start_tick` — new start tick
  - `:key` — new pitch
  """
  @spec drag_note(
          t(),
          %{optional(:start_tick) => Tick.t(), optional(:key) => Key.t()}
          | keyword(Tick.t() | Key.t())
        ) ::
          {:ok, t()} | {:error, term()}
  def drag_note(note, new_key_or_tick) do
    {new_key, new_key_or_tick} = new_key_or_tick |> Map.new() |> Map.pop(:key, note.key)
    {new_start_tick, new_key_or_tick} = Map.pop(new_key_or_tick, :start_tick, note.start_tick)

    with 0 <- map_size(new_key_or_tick) do
      update(note, key: new_key, start_tick: new_start_tick)
    else
      _num -> {:error, {:extra_fields_exist, new_key_or_tick}}
    end
  end

  @doc "Update note's duration."
  @spec drag_duration(t(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def drag_duration(note, new_duraion) do
    update(note, duration_tick: new_duraion)
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
  Splits a note at an absolute tick position.

  Returns `{:ok, note_before, note_after}`. The trailing note gets a new ID.
  `split_tick` must fall strictly inside the note (`start_tick < split_tick < end_tick`).

  `attrs` optionally overrides fields on the trailing note (e.g. a different lyric).
  """
  @spec split(t(), Tick.t(), ID.t(t()), map() | keyword()) :: {:ok, t(), t()} | {:error, term()}
  def split(note, split_tick, new_id, attrs \\ []) do
    note_end = note.start_tick + note.duration_tick

    cond do
      split_tick <= note.start_tick ->
        {:error, {:split_tick_before_note, split_tick, note.start_tick}}

      split_tick >= note_end ->
        {:error, {:split_tick_after_note, split_tick, note_end}}

      true ->
        {:ok, before} = update(note, duration_tick: split_tick - note.start_tick)

        extra_attrs =
          attrs
          |> Enum.into(%{})
          # Ensure NoteID and tick exist
          |> Map.take([:key, :lyric, :annotation, :metadata])

        after_attrs =
          Map.merge(
            %{
              id: new_id,
              start_tick: split_tick,
              duration_tick: note_end - split_tick,
              key: note.key,
              lyric: note.lyric,
              annotation: note.annotation,
              metadata: note.metadata
            },
            extra_attrs
          )

        case new(after_attrs) do
          {:ok, after_note} -> {:ok, before, after_note}
          {:error, _} = err -> err
        end
    end
  end

  @doc """
  Merges two notes.

  `merged_id` is injected by the caller — Note does not generate IDs.

  ## Options

  - `:gap_tolerance` — maximum allowed gap between notes in ticks (default 0: must be adjacent or overlapping)
  - `:lyric_merger` — pluggable lyric concatenation function (`({Note.t(), Note.t()} -> {:ok, term()} | {:error, term()})`); defaults to concatenating when both are non-nil
  - `:annotation_merger` — pluggable annotation merge function (`({Note.t(), Note.t()} -> {:ok, term()} | {:error, term()})`); defaults to the first non-nil value

  ## Behaviour

  - Both notes must share the same pitch (compared via `Key.to_midi/1`)
  - Must overlap, or gap ≤ `gap_tolerance`
  - Returns `{:ok, merged_note}` with the given `merged_id`
  - Merged annotation takes the first non-nil value
  """
  @spec merge(t(), t(), ID.t(t()), keyword()) :: {:ok, t()} | {:error, term()}
  def merge(note1, note2, merged_id, opts \\ []) do
    gap_tolerance = Keyword.get(opts, :gap_tolerance, 0)
    note1_end = note1.start_tick + note1.duration_tick
    note2_end = note2.start_tick + note2.duration_tick

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

      note1_end + gap_tolerance < note2.start_tick or
          note2_end + gap_tolerance < note1.start_tick ->
        {:error, {:gap_too_large, note1_end, note2.start_tick, gap_tolerance}}

      true ->
        do_merge(note1, note1_end, note2, note2_end, merged_id, lyric_merger, annotation_merger)
    end
  end

  # ---- Toolkit functions ----

  # Execute merge
  defp do_merge(note1, note1_end, note2, note2_end, merged_id, lyric_merger, annotation_merger) do
    start_tick = min(note1.start_tick, note2.start_tick)
    end_tick = max(note1_end, note2_end)

    with {:ok, lyric} <- lyric_merger.(note1, note2),
         {:ok, annotation} <- annotation_merger.(note1, note2) do
      %{
        id: merged_id,
        start_tick: start_tick,
        duration_tick: end_tick - start_tick,
        key: note1.key,
        lyric: lyric,
        annotation: annotation,
        metadata: Map.merge(note1.metadata, note2.metadata)
      }
      |> new()
    end
  end
end
