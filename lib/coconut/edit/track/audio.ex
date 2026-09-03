defmodule Coconut.Edit.Track.Audio do
  @moduledoc """
  Audio track: frame-domain, `Clip` elements (design doc §11.8).

  Both a clip's placement (its span) and its content addressing
  (`source_offset_frames` / `duration_frames`) live in the frame/sample
  domain, so tempo edits never drift audio (§4's "tick warp 与 tempo 无关"
  hard rule; import-time conversion through the TempoMap is the caller's
  business). The frame *unit* is the render engine's frame grid (hop frames
  for DiffSinger), declared as engine/project metadata — the kernel sees
  integer frame numbers only and never interprets the unit (§4's
  "帧/采样点 = 引擎层坐标"). v1 does no time-stretch: a clip's span length
  always equals its `duration_frames`. The invariant is enforced at the gesture
  boundaries — insert casts reject a duration/span mismatch, drags that
  would change the span length are rejected (`:drag` gesture), edge
  changes go through trim (`retime_element/3` compensation), never drag,
  and content edits refuse `duration_frames` outright
  (`:audio_duration_edit_rejected` — only trim/split may resize).

  The kernel treats `source` as opaque (a file path or an asset reference —
  the assets table is a v2 concern); source *length* is asset-layer
  knowledge, so the only content boundary guarded here is a non-negative
  source offset.
  """

  use Coconut.Edit.Track

  alias Coconut.Edit.Track

  defmodule Clip do
    @moduledoc """
    An audio clip: a window into a source, addressed in frames.

    `duration_frames` duplicates the clip's span length under the v1
    no-stretch rule; it is restated on the element because it is *content*
    addressing (how much of the source the clip consumes), maintained by
    the split/trim hooks.
    """

    @type t :: %__MODULE__{
            source: String.t(),
            source_offset_frames: non_neg_integer(),
            duration_frames: pos_integer()
          }

    @enforce_keys [:source, :source_offset_frames, :duration_frames]
    defstruct @enforce_keys
  end

  @impl Coconut.Edit.Track
  def coord_domain, do: :frame

  @impl Coconut.Edit.Track
  def cast_element(_id, {start_f, end_f}, attrs) do
    with {:ok, source} <- cast_source(Map.get(attrs, :source)),
         {:ok, offset} <- cast_offset(Map.get(attrs, :source_offset_frames, 0)),
         {:ok, duration} <- cast_duration(Map.get(attrs, :duration_frames)),
         :ok <- check_no_stretch(duration, end_f - start_f) do
      {:ok, %Clip{source: source, source_offset_frames: offset, duration_frames: duration}}
    end
  end

  # 内容编辑不携带 span 几何，duration ↔ span 等长不变式在手势边界
  # （insert/trim/split）维护——duration_frames 只允许经那些手势改变，
  # 内容编辑直接改它会让元素声明长度与 span 脱节，这里拒收。
  @impl Coconut.Edit.Track
  def edit_element(%Clip{}, %{duration_frames: _}), do: {:error, :audio_duration_edit_rejected}

  def edit_element(%Clip{} = element, changes) do
    merged =
      %{
        source: element.source,
        source_offset_frames: element.source_offset_frames,
        duration_frames: element.duration_frames
      }
      |> Map.merge(Map.take(changes, [:source, :source_offset_frames]))

    with {:ok, source} <- cast_source(merged.source),
         {:ok, offset} <- cast_offset(merged.source_offset_frames),
         {:ok, duration} <- cast_duration(merged.duration_frames) do
      {:ok, %Clip{source: source, source_offset_frames: offset, duration_frames: duration}}
    end
  end

  @impl Coconut.Edit.Track
  def validate_gesture(:drag, _track, %{old_span: {os, oe}, new_span: {ns, ne}}) do
    if ne - ns == oe - os do
      :ok
    else
      {:error, {:audio_stretch_rejected, %{old_span: {os, oe}, new_span: {ns, ne}}}}
    end
  end

  def validate_gesture(:merge, _track, %{ids: ids}) do
    {:error, {:audio_merge_unsupported, ids}}
  end

  def validate_gesture(_gesture, _track, _info), do: :ok

  @impl Coconut.Edit.Track
  def validate_state(track) do
    spans = Track.latest_spans(track)

    Enum.find_value(track.space.ids, :ok, fn id ->
      with %Clip{} = clip <- Map.get(track.elements_by_id, id),
           true <- valid_clip?(clip),
           {start_frame, end_frame} <- Map.get(spans, id),
           :ok <- check_no_stretch(clip.duration_frames, end_frame - start_frame) do
        nil
      else
        nil -> {:error, {:incomplete_audio_track, id}}
        {:error, _} = error -> error
        _other -> {:error, {:invalid_audio_clip, id}}
      end
    end)
  end

  defp valid_clip?(clip) do
    is_binary(clip.source) and clip.source != "" and
      is_integer(clip.source_offset_frames) and clip.source_offset_frames >= 0 and
      is_integer(clip.duration_frames) and clip.duration_frames > 0
  end

  @impl Coconut.Edit.Track
  def split_elements(%Clip{} = parent, %{span: {start_f, _end_f}, at: at}) do
    left_frames = at - start_f

    left = %{parent | duration_frames: left_frames}

    right = %Clip{
      source: parent.source,
      source_offset_frames: parent.source_offset_frames + left_frames,
      duration_frames: parent.duration_frames - left_frames
    }

    {left, right}
  end

  @impl Coconut.Edit.Track
  def retime_element(%Clip{} = element, {old_start, _old_end}, {new_start, new_end}) do
    offset = element.source_offset_frames + (new_start - old_start)

    if offset < 0 do
      {:error, {:audio_source_underflow, offset}}
    else
      {:ok, %{element | source_offset_frames: offset, duration_frames: new_end - new_start}}
    end
  end

  @impl Coconut.Edit.Track
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

  # ---- 字段形状 ----

  defp cast_source(source) when is_binary(source) and source != "", do: {:ok, source}
  defp cast_source(other), do: {:error, {:invalid_clip_source, other}}

  defp cast_offset(offset) when is_integer(offset) and offset >= 0, do: {:ok, offset}
  defp cast_offset(other), do: {:error, {:invalid_clip_offset, other}}

  defp cast_duration(duration) when is_integer(duration) and duration > 0, do: {:ok, duration}
  defp cast_duration(other), do: {:error, {:invalid_clip_duration, other}}

  defp check_no_stretch(duration, span_frames) do
    if duration == span_frames do
      :ok
    else
      {:error,
       {:clip_duration_span_mismatch, %{duration_frames: duration, span_frames: span_frames}}}
    end
  end
end
