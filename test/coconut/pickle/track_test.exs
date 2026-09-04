defmodule Coconut.Pickle.TrackTest do
  use ExUnit.Case, async: true

  import Coconut.PickleHelper

  alias Coconut.Edit.{Patch, Track}
  alias Coconut.Pickle.Track, as: PickleTrack
  alias Coconut.Score
  alias Tamale.Anchor.Ordinal

  defp vocal_track do
    {:ok, n1} =
      Score.Note.new(%{
        id: "n1",
        key: %Score.Key.TwelveET{midi: 60},
        lyric: "ら",
        metadata: %{"velocity" => 64}
      })

    {:ok, n2} = Score.Note.new(%{id: "n2", key: nil, lyric: "ー"})

    {:ok, track} =
      Track.new(%{
        id: "vocal",
        module: Track.Vocal,
        space: %Tamale.Space{ids: ["n1", "n2"], seen: MapSet.new(["n1", "n2"])},
        spans_by_version: %{0 => %{"n1" => {0, 480}, "n2" => {480, 960}}},
        elements_by_id: %{"n1" => n1, "n2" => n2}
      })

    track
  end

  describe "dump/2 + load/2 round-trip" do
    test "vocal track with notes round-trips" do
      track = vocal_track()
      registry = PickleTrack.default_registry()

      assert {:ok, dumped} = PickleTrack.dump(track, registry)
      assert dumped.id == "vocal"
      assert dumped.module == "vocal"

      assert dumped.spans_by_version == %{
               0 => %{"n1" => %{start: 0, stop: 480}, "n2" => %{start: 480, stop: 960}}
             }

      assert dumped.elements_by_id["n1"].key === %{module: Score.Key.TwelveET, midi: 60}

      assert_pickle_conform(dumped)
      assert {:ok, loaded} = PickleTrack.load(dumped, registry)
      assert loaded == track
    end

    test "metadata/extras round-trip，旧档缺字段时回落空 map" do
      {:ok, track} =
        Track.new(%{
          id: "rich",
          module: Track.Vocal,
          metadata: %{"color" => "蓝", role: :lead},
          extras: %{neume: %{version: 1, gains: [1.0, nil]}}
        })

      registry = PickleTrack.default_registry()
      assert {:ok, dumped} = PickleTrack.dump(track, registry)
      assert dumped.metadata == track.metadata
      assert dumped.extras == track.extras
      assert_pickle_conform(dumped)
      assert {:ok, ^track} = PickleTrack.load(dumped, registry)

      legacy = dumped |> Map.delete(:metadata) |> Map.delete(:extras)
      assert {:ok, loaded} = PickleTrack.load(legacy, registry)
      assert loaded.metadata == %{}
      assert loaded.extras == %{}
    end

    test "name is optional: dumped through, absent loads as nil" do
      {:ok, named} = Track.new(%{id: "v2", module: Track.Vocal, name: "主唱"})
      {:ok, plain} = Track.new(%{id: "v3", module: Track.Vocal})
      registry = PickleTrack.default_registry()

      assert {:ok, dumped} = PickleTrack.dump(named, registry)
      assert dumped.name == "主唱"
      assert_pickle_conform(dumped)
      assert {:ok, loaded} = PickleTrack.load(dumped, registry)
      assert loaded == named

      # old archives without a name key load as nil
      assert {:ok, plain_dumped} = PickleTrack.dump(plain, registry)
      assert {:ok, loaded_plain} = PickleTrack.load(Map.delete(plain_dumped, :name), registry)
      assert loaded_plain.name == nil
      assert loaded_plain == plain
    end

    test "tempo track with bpm events round-trips" do
      {:ok, track} =
        Track.new(%{
          id: "tempo",
          module: Track.Tempo,
          space: %Tamale.Space{ids: ["t0"], seen: MapSet.new(["t0"])},
          spans_by_version: %{0 => %{"t0" => {0, 1920}}},
          elements_by_id: %{"t0" => %{bpm: 120_000}}
        })

      registry = PickleTrack.default_registry()

      assert {:ok, dumped} = PickleTrack.dump(track, registry)
      assert dumped.module == "tempo"
      assert dumped.elements_by_id == %{"t0" => %{bpm: 120_000}}

      assert_pickle_conform(dumped)
      assert {:ok, loaded} = PickleTrack.load(dumped, registry)
      assert loaded == track
    end

    test "track with patches and empty dead_patches round-trips" do
      {:ok, cp} =
        Patch.new(%{
          id: "Patch_1",
          track_id: "vocal",
          anchor: %Ordinal{refs: ["n1"], at_version: 0},
          patch: %Tamale.Patch{base_digest: "abc", payload: [[0, 60]]},
          channel: :pitch
        })

      track = %{vocal_track() | patches: [cp]}
      registry = PickleTrack.default_registry()

      assert {:ok, dumped} = PickleTrack.dump(track, registry)
      assert [patch_dump] = dumped.patches
      assert patch_dump.anchor.module == Ordinal
      assert dumped.dead_patches == []

      assert_pickle_conform(dumped)
      assert {:ok, loaded} = PickleTrack.load(dumped, registry)
      assert loaded == track
    end

    test "dead_patches entries encode as [patch_dump, reason] pairs" do
      {:ok, cp} =
        Patch.new(%{
          id: "Patch_1",
          track_id: "vocal",
          anchor: %Ordinal{refs: ["n1"], at_version: 0},
          patch: %Tamale.Patch{base_digest: "abc", payload: []},
          channel: :pitch
        })

      track = %{vocal_track() | dead_patches: [{cp, "boundary_merged"}]}
      registry = PickleTrack.default_registry()

      assert {:ok, dumped} = PickleTrack.dump(track, registry)
      assert [[_patch_dump, "boundary_merged"]] = dumped.dead_patches

      assert_pickle_conform(dumped)
      assert {:ok, loaded} = PickleTrack.load(dumped, registry)
      assert loaded == track
    end

    test "empty elements table passes without an element codec" do
      {:ok, track} = Track.new(%{id: "fake", module: String})
      {:ok, registry} = Coconut.Pickle.Registry.new(%{"fake" => String})

      assert {:ok, dumped} = PickleTrack.dump(track, registry)
      assert {:ok, loaded} = PickleTrack.load(dumped, registry)
      assert loaded == track
    end
  end

  describe "error paths" do
    test "dump with unregistered module reports {:unregistered_module, _}" do
      {:ok, empty} = Coconut.Pickle.Registry.new(%{})

      assert {:error, {:unregistered_module, Track.Vocal}} =
               PickleTrack.dump(vocal_track(), empty)
    end

    test "load with unknown type name reports {:unknown_type_name, _}" do
      registry = PickleTrack.default_registry()
      assert {:ok, dumped} = PickleTrack.dump(vocal_track(), registry)

      assert {:error, {:unknown_type_name, "vocal"}} =
               PickleTrack.load(dumped, elem(Coconut.Pickle.Registry.new(%{}), 1))
    end

    test "module without element codec and non-empty elements errors" do
      {:ok, track} =
        Track.new(%{id: "fake", module: String, elements_by_id: %{"e1" => "data"}})

      {:ok, registry} = Coconut.Pickle.Registry.new(%{"fake" => String})

      assert {:error, {:missing_element_codec, String}} = PickleTrack.dump(track, registry)
    end

    test "dump 边界拒绝绕过 constructor 注入的非 conform 自由字段" do
      registry = PickleTrack.default_registry()
      track = %{vocal_track() | extras: %{runtime: self()}}

      assert {:error, {:non_conform_extras, _}} = PickleTrack.dump(track, registry)
    end

    test "non-conform dead reason is an error" do
      {:ok, cp} =
        Patch.new(%{
          id: "Patch_1",
          track_id: "vocal",
          anchor: %Ordinal{refs: ["n1"], at_version: 0},
          patch: %Tamale.Patch{base_digest: "abc", payload: []},
          channel: :pitch
        })

      track = %{vocal_track() | dead_patches: [{cp, {:undefined, :boundary_merged}}]}
      registry = PickleTrack.default_registry()

      assert {:error, {:non_conform_dead_reason, {:undefined, :boundary_merged}}} =
               PickleTrack.dump(track, registry)
    end

    test "malformed span dump is an error tuple" do
      registry = PickleTrack.default_registry()
      assert {:ok, dumped} = PickleTrack.dump(vocal_track(), registry)
      bad = put_in(dumped.spans_by_version[0]["n1"], [0, 480, 960])

      assert {:error, {:invalid_span_dump, [0, 480, 960]}} = PickleTrack.load(bad, registry)
    end
  end
end
