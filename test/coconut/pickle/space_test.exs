defmodule Coconut.Pickle.SpaceTest do
  use ExUnit.Case, async: true

  import Coconut.PickleHelper

  alias Coconut.Pickle.Space, as: PickleSpace
  alias Tamale.Op.{Delete, Insert, Retime}
  alias Tamale.Space

  # genesis ["n1", "n2"] 后落两批：v1 insert+retime，v2 delete
  defp build_space do
    {:ok, space} =
      Space.new(["n1", "n2"])
      |> then(fn {:ok, s} ->
        Space.apply_batch(s, [
          %Insert{id: "n3", after_id: "n2"},
          %Retime{id: "n1", old_span: {0, 480}, new_span: {{1, 3}, 240}}
        ])
      end)

    {:ok, space} = Space.apply_batch(space, [%Delete{id: "n2"}])
    space
  end

  describe "dump/1 + load/1 round-trip" do
    test "space with multi-version log and non-empty seen round-trips" do
      space = build_space()

      assert {:ok, dumped} = PickleSpace.dump(space)
      assert dumped.ids == ["n1", "n3"]
      assert dumped.version == 2
      assert dumped.base_version == 0
      assert is_list(dumped.seen)
      assert dumped.seen == Enum.sort(dumped.seen)
      assert [[1, [_insert, _retime]], [2, [_delete]]] = dumped.log

      assert_pickle_conform(dumped)
      assert {:ok, loaded} = PickleSpace.load(dumped)
      assert loaded == space
      assert %MapSet{} = loaded.seen
    end

    test "empty genesis space round-trips" do
      {:ok, space} = Space.new([])
      assert {:ok, dumped} = PickleSpace.dump(space)
      assert dumped.log == []
      assert dumped.seen == []
      assert_pickle_conform(dumped)
      assert {:ok, loaded} = PickleSpace.load(dumped)
      assert loaded == space
    end

    test "truncated space (non-zero base_version) round-trips" do
      space = build_space() |> Space.truncate(1)
      assert {:ok, dumped} = PickleSpace.dump(space)
      assert dumped.base_version == 1
      assert {:ok, loaded} = PickleSpace.load(dumped)
      assert loaded == space
    end

    test "rational Retime spans inside the log survive the round-trip" do
      space = build_space()
      assert {:ok, dumped} = PickleSpace.dump(space)
      [[1, [_insert_dump, retime_dump]], _] = dumped.log
      assert retime_dump.new_span == [[1, 3], 240]

      assert {:ok, loaded} = PickleSpace.load(dumped)
      assert loaded.log == space.log
    end
  end

  describe "load/1 invalid input" do
    test "non-map input is an error tuple, not a raise" do
      assert {:error, {:invalid_space_dump, "space"}} = PickleSpace.load("space")
    end

    test "missing fields are an error tuple" do
      assert {:error, {:invalid_space_dump, %{ids: []}}} = PickleSpace.load(%{ids: []})
    end

    test "malformed log entry is an error tuple" do
      assert {:error, {:invalid_space_dump, _}} =
               PickleSpace.load(%{
                 ids: [],
                 version: 1,
                 log: [[1, "not-a-list"]],
                 base_version: 0,
                 seen: []
               })
    end

    test "invalid op inside the log is an error tuple" do
      assert {:error, {:invalid_space_dump, _}} =
               PickleSpace.load(%{
                 ids: [],
                 version: 1,
                 log: [[1, [%{module: No.Such.Op}]]],
                 base_version: 0,
                 seen: []
               })
    end

    test "dump of a non-space term is an error tuple" do
      assert {:error, {:invalid_space, %{}}} = PickleSpace.dump(%{})
    end
  end
end
