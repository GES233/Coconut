defmodule Coconut.Edit.Track.Vocal do
  @moduledoc """
  Vocal track: tick-domain, `Coconut.Score.Note` elements.

  Elements are pure content carriers (design doc §11.2) — timing lives in
  the track's spans table. v1 adds no gesture constraints beyond the
  generic ones; same-track note overlap rejection is a v2
  `validate_gesture/3` (design doc §11.8).
  """

  use Coconut.Edit.Track
  @behaviour Coconut.Edit.Track.ElementCodec

  alias Coconut.Edit.Track
  alias Coconut.Score.{Key, Note}

  @impl true
  def coord_domain, do: :tick

  @impl true
  def cast_element(id, _span, attrs), do: Note.from_element(id, attrs)

  @impl true
  def edit_element(%Note{} = element, changes) do
    {known, metadata} = Map.split(changes, [:pitch, :lyric, :annotation])

    attrs =
      %{pitch: element.key, lyric: element.lyric, annotation: element.annotation}
      |> Map.merge(known)
      |> Map.merge(element.metadata)
      |> Map.merge(Map.new(metadata, fn {k, v} -> {to_string(k), v} end))

    Note.from_element(element.id, attrs)
  end

  @impl true
  def split_elements(%Note{} = parent, %{new_id: new_id}), do: {parent, %{parent | id: new_id}}

  # 可选能力 :element_codec（Coconut.Edit.Track.ElementCodec）：元素编解码。
  # 除 `key` 外字段直出；`key` 摊平为 `%{module: key.__struct__, midi: Key.to_midi(key)}`，
  # load 时经 `module.from_midi(midi, nil)` 重建（key 为 nil 时原样保留 nil，
  # 如 Rap 音符）。其余字段经 `Coconut.Score.Note.new/1` 重建（校验生效）。
  @impl Coconut.Edit.Track.ElementCodec
  def dump_element(%Note{} = note) do
    {:ok,
     %{
       id: note.id,
       key: dump_key(note.key),
       lyric: note.lyric,
       annotation: note.annotation,
       metadata: note.metadata
     }}
  end

  @impl Coconut.Edit.Track.ElementCodec
  def load_element(%{} = data) do
    with {:ok, key} <- load_key(Map.get(data, :key)) do
      data
      |> Map.put(:key, key)
      |> Note.new()
    end
  end

  defp dump_key(nil), do: nil
  defp dump_key(%module{} = key), do: %{module: module, midi: Key.to_midi(key)}

  defp load_key(nil), do: {:ok, nil}

  # 未知 key module：from_midi 自然报错（或未实现），包装为 error tuple，不 raise
  defp load_key(%{module: module, midi: midi} = dumped)
       when is_atom(module) and is_number(midi) do
    module.from_midi(midi, nil)
  rescue
    _ -> {:error, {:key_from_midi_failed, dumped}}
  end

  defp load_key(other), do: {:error, {:invalid_key_dump, other}}

  @impl true
  def view(track) do
    track
    |> Track.latest_spans()
    |> Enum.flat_map(fn {id, span} ->
      case Map.fetch(track.elements_by_id, id) do
        {:ok, element} -> [{id, element, span}]
        :error -> []
      end
    end)
    |> Enum.sort_by(fn {id, _element, {start, _end}} -> {start, id} end)
  end
end
