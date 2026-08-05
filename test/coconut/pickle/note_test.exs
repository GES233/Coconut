defmodule Coconut.Pickle.NoteTest do
  use ExUnit.Case, async: true

  import Coconut.PickleHelper

  alias Coconut.Pickle.Note, as: PickleNote
  alias Coconut.Score.{Key, Note}

  describe "dump/1" do
    test "dumps every field, key flattened with module tag" do
      {:ok, note} =
        Note.new(%{
          id: "n1",
          key: %Key.TwelveET{midi: 60},
          lyric: "ら",
          annotation: "stress",
          metadata: %{"phonemes" => [["r", "a"]]}
        })

      assert {:ok, dumped} = PickleNote.dump(note)

      assert dumped == %{
               id: "n1",
               key: %{module: Key.TwelveET, midi: 60.0},
               lyric: "ら",
               annotation: "stress",
               metadata: %{"phonemes" => [["r", "a"]]}
             }

      assert_pickle_conform(dumped)
    end

    test "nil key (e.g. rap) round-trips as nil" do
      {:ok, note} = Note.new(%{id: "n1", key: nil, lyric: nil})
      assert {:ok, dumped} = PickleNote.dump(note)
      assert dumped.key == nil
      assert {:ok, loaded} = PickleNote.load(dumped)
      assert loaded == note
    end
  end

  describe "load/1" do
    test "round-trip preserves the note" do
      {:ok, note} =
        Note.new(%{
          id: "n1",
          key: %Key.TwelveET{midi: 60.5},
          lyric: "啦",
          metadata: %{"phonemes" => [["l", "a"]], "velocity" => 64}
        })

      assert {:ok, dumped} = PickleNote.dump(note)
      assert {:ok, loaded} = PickleNote.load(dumped)
      assert loaded == note
    end

    test "missing id surfaces Note.new/1's validation error" do
      assert {:error, {:missing_id, "Note_"}} =
               PickleNote.load(%{key: nil, lyric: "x"})
    end

    test "invalid key dump is an error tuple, not a raise" do
      assert {:error, {:invalid_key_dump, "c4"}} =
               PickleNote.load(%{id: "n1", key: "c4"})
    end

    test "unknown key module is wrapped, not raised" do
      assert {:error, {:key_from_midi_failed, %{module: No.Such.Key, midi: 60}}} =
               PickleNote.load(%{id: "n1", key: %{module: No.Such.Key, midi: 60}})
    end
  end
end
