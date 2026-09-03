defmodule Coconut.Pickle.ElementCodec.VocalTest do
  use ExUnit.Case, async: true

  import Coconut.PickleHelper

  alias Coconut.Pickle.ElementCodec.Vocal
  alias Coconut.Score.{Key, Note}

  describe "dump_element/1" do
    test "dumps every field, key flattened with module tag" do
      {:ok, note} =
        Note.new(%{
          id: "n1",
          key: %Key.TwelveET{midi: 60},
          lyric: "ら",
          annotation: "stress",
          metadata: %{"phonemes" => [["r", "a"]]}
        })

      assert {:ok, dumped} = Vocal.dump_element(note)

      assert dumped === %{
               id: "n1",
               key: %{module: Key.TwelveET, midi: 60},
               lyric: "ら",
               annotation: "stress",
               metadata: %{"phonemes" => [["r", "a"]]}
             }

      assert_pickle_conform(dumped)
    end

    test "nil key (e.g. rap) round-trips as nil" do
      {:ok, note} = Note.new(%{id: "n1", key: nil, lyric: nil})
      assert {:ok, dumped} = Vocal.dump_element(note)
      assert dumped.key == nil
      assert {:ok, loaded} = Vocal.load_element(dumped)
      assert loaded == note
    end
  end

  describe "load_element/1" do
    test "整数 MIDI 精确 round-trip" do
      {:ok, note} =
        Note.new(%{
          id: "n1",
          key: %Key.TwelveET{midi: 60},
          lyric: "啦"
        })

      assert {:ok, dumped} = Vocal.dump_element(note)
      assert dumped.key.midi === 60
      assert {:ok, loaded} = Vocal.load_element(dumped)
      assert loaded === note
      assert loaded.key.midi === 60
    end

    test "小数 MIDI 由 adapter 以十进制字符串 round-trip" do
      {:ok, note} =
        Note.new(%{
          id: "n1",
          key: %Key.TwelveET{midi: 60.5},
          lyric: "啦",
          metadata: %{"phonemes" => [["l", "a"]], "velocity" => 64}
        })

      assert {:ok, dumped} = Vocal.dump_element(note)
      assert dumped.key.midi === "60.5"
      assert {:ok, loaded} = Vocal.load_element(dumped)
      assert loaded === note
    end

    test "兼容旧 codec 写出的整数值 float" do
      dumped = %{
        id: "n1",
        key: %{module: Key.TwelveET, midi: 60.0},
        lyric: "啦",
        annotation: nil,
        metadata: %{}
      }

      assert {:ok, loaded} = Vocal.load_element(dumped)
      assert loaded.key.midi === 60
    end

    test "missing id surfaces Note.new/1's validation error" do
      assert {:error, {:missing_id, "Note_"}} =
               Vocal.load_element(%{key: nil, lyric: "x"})
    end

    test "invalid key dump is an error tuple, not a raise" do
      assert {:error, {:invalid_key_dump, "c4"}} =
               Vocal.load_element(%{id: "n1", key: "c4"})
    end

    test "unknown key module is wrapped, not raised" do
      assert {:error, {:key_load_failed, %{module: No.Such.Key, midi: 60}}} =
               Vocal.load_element(%{id: "n1", key: %{module: No.Such.Key, midi: 60}})
    end
  end
end
