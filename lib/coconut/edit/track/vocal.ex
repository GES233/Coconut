defmodule Coconut.Edit.Track.Vocal do
  @moduledoc """
  Vocal track: tick-domain, `Coconut.Score.Note` elements.

  Elements are pure content carriers (design doc §11.2) — timing lives in
  the track's spans table. Same-track note overlap is rejected at the
  gesture boundary (`validate_gesture/3`, design doc §11.8): spans are
  half-open intervals, so abutting notes (`end == start`) are legal.
  """

  use Coconut.Edit.Track

  alias Coconut.Edit.Track
  alias Coconut.Score.Note

  @impl true
  def coord_domain, do: :tick

  @impl true
  def cast_element(id, _span, attrs), do: Note.from_element(id, attrs)

  # 同轨不重叠：insert/drag/trim 的新 span、merge 的复合 span 都不得压住
  # 其他存活音符（半开区间，相邻合法）。split 由父 span 切开、delete 只
  # 减不增，天然不引入重叠，走默认放行。
  @impl true
  def validate_gesture(:insert, track, %{span: span}), do: check_overlap(track, span, [])

  def validate_gesture(gesture, track, %{id: id, new_span: span})
      when gesture in [:drag, :trim],
      do: check_overlap(track, span, [id])

  def validate_gesture(:merge, track, %{ids: ids}) do
    # validate 先于 ensure_all_live 运行，此处 span 必存在；复合 span 取
    # 最早 start 到最晚 end（与 MergeNotes.lower 同一形状）。
    {starts, ends} = ids |> Enum.map(&Track.latest_span(track, &1)) |> Enum.unzip()
    check_overlap(track, {Enum.min(starts), Enum.max(ends)}, ids)
  end

  def validate_gesture(_gesture, _track, _info), do: :ok

  defp check_overlap(track, {s, e}, exclude_ids) do
    conflicts =
      track
      |> Track.latest_spans()
      |> Enum.reject(fn {id, _} -> id in exclude_ids end)
      |> Enum.filter(fn {_id, {s2, e2}} -> s < e2 and s2 < e end)
      |> Enum.map(fn {id, _span} -> id end)
      |> Enum.sort()

    case conflicts do
      [] -> :ok
      _ -> {:error, {:vocal_overlap_rejected, %{span: {s, e}, conflicting: conflicts}}}
    end
  end

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
