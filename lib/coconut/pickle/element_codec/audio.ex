defmodule Coconut.Pickle.ElementCodec.Audio do
  @moduledoc """
  `Coconut.Edit.Track.Audio` 的元素 codec（`Clip`）。

  Clip 摊平为 source 字符串 + 两个整数帧字段的 plain map，load 反向重建并校验形状。
  """

  @behaviour Coconut.Pickle.ElementCodec

  alias Coconut.Edit.Track.Audio.Clip

  @impl true
  def element_module, do: Clip

  @impl true
  def dump_element(%Clip{} = clip) do
    {:ok,
     %{
       source: clip.source,
       source_offset_frames: clip.source_offset_frames,
       duration_frames: clip.duration_frames
     }}
  end

  @impl true
  def load_element(%{} = dumped) do
    with {:ok, source} <- cast_source(Map.get(dumped, :source)),
         {:ok, offset} <- cast_offset(Map.get(dumped, :source_offset_frames)),
         {:ok, duration} <- cast_duration(Map.get(dumped, :duration_frames)) do
      {:ok, %Clip{source: source, source_offset_frames: offset, duration_frames: duration}}
    end
  end

  def load_element(other), do: {:error, {:invalid_clip_dump, other}}

  # 与 `Coconut.Edit.Track.Audio` 的字段形状校验保持一致（那边是 insert/edit
  # 手势边界在用，这边是归档边界在用，各自私有）。
  defp cast_source(source) when is_binary(source) and source != "", do: {:ok, source}
  defp cast_source(other), do: {:error, {:invalid_clip_source, other}}

  defp cast_offset(offset) when is_integer(offset) and offset >= 0, do: {:ok, offset}
  defp cast_offset(other), do: {:error, {:invalid_clip_offset, other}}

  defp cast_duration(duration) when is_integer(duration) and duration > 0, do: {:ok, duration}
  defp cast_duration(other), do: {:error, {:invalid_clip_duration, other}}
end
