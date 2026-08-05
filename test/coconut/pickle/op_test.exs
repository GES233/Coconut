defmodule Coconut.Pickle.OpTest do
  use ExUnit.Case, async: true

  import Coconut.PickleHelper

  alias Coconut.Pickle.Op, as: PickleOp
  alias Tamale.Op.{Delete, Insert, Merge, Move, Retime, Split}

  describe "dump/1 + load/1 round-trip" do
    test "all six op variants round-trip" do
      ops = [
        %Insert{id: "n2", after_id: "n1"},
        %Insert{id: "n0", after_id: :head},
        %Delete{id: "n3"},
        %Split{id: "n1", children: ["n1", "n1b", "n1c"]},
        %Merge{ids: ["n1", "n2", "n3"], into: "n1"},
        %Move{id: "n4", after_id: :head},
        %Retime{id: "n1", old_span: {0, 480}, new_span: {0, 240}}
      ]

      for op <- ops do
        assert {:ok, dumped} = PickleOp.dump(op)
        assert_pickle_conform(dumped)
        assert {:ok, loaded} = PickleOp.load(dumped)
        assert loaded == op
      end
    end

    test "Retime round-trips rational span endpoints" do
      op = %Retime{id: "n1", old_span: {{1, 3}, 480}, new_span: {0, {7, 2}}}
      assert {:ok, dumped} = PickleOp.dump(op)

      assert dumped.old_span == [[1, 3], 480]
      assert dumped.new_span == [0, [7, 2]]

      assert_pickle_conform(dumped)
      assert {:ok, loaded} = PickleOp.load(dumped)
      assert loaded == op
    end
  end

  describe "load/1 invalid input" do
    test "unknown module tag is an error tuple, not a raise" do
      assert {:error, {:invalid_op_dump, %{module: No.Such.Op}}} =
               PickleOp.load(%{module: No.Such.Op})
    end

    test "non-map input is an error tuple" do
      assert {:error, {:invalid_op_dump, "insert"}} = PickleOp.load("insert")
    end

    test "malformed Retime span is an error tuple" do
      assert {:error, {:invalid_op_dump, _}} =
               PickleOp.load(%{module: Retime, id: "n1", old_span: [0, 1, 2], new_span: [0, 1]})

      assert {:error, {:invalid_op_dump, _}} =
               PickleOp.load(%{module: Retime, id: "n1", old_span: [0.5, 1], new_span: [0, 1]})
    end

    test "dump of a non-op term is an error tuple" do
      assert {:error, {:invalid_op, %{id: "n1"}}} = PickleOp.dump(%{id: "n1"})
    end
  end
end
