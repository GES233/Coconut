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
  alias Coconut.Score.Note

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
  def split_inherit(%Note{} = parent, new_id), do: %{parent | id: new_id}

  # 可选能力 :element_codec（Coconut.Edit.Track.ElementCodec）：元素编解码
  # 委托 Coconut.Pickle.Note。
  @impl Coconut.Edit.Track.ElementCodec
  def dump_element(%Note{} = note), do: Coconut.Pickle.Note.dump(note)

  @impl Coconut.Edit.Track.ElementCodec
  def load_element(dumped), do: Coconut.Pickle.Note.load(dumped)

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
