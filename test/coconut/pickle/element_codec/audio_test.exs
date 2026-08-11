defmodule Coconut.Pickle.ElementCodec.AudioTest do
  use ExUnit.Case, async: true

  alias Coconut.Edit.Track.Audio.Clip
  alias Coconut.Pickle.ElementCodec.Audio

  describe "dump_element/1 + load_element/1" do
    test "dump/load roundtrip" do
      clip = %Clip{source: "a.wav", source_offset_frames: 10, duration_frames: 100}

      assert {:ok, dumped} = Audio.dump_element(clip)
      assert dumped == %{source: "a.wav", source_offset_frames: 10, duration_frames: 100}
      assert {:ok, ^clip} = Audio.load_element(dumped)

      assert {:error, {:invalid_clip_offset, -1}} =
               Audio.load_element(%{dumped | source_offset_frames: -1})

      assert {:error, {:invalid_clip_dump, "nope"}} = Audio.load_element("nope")
    end
  end
end
