defmodule Coconut.Pickle.TupleCodecTest do
  use ExUnit.Case, async: true

  import Coconut.PickleHelper

  alias Coconut.Pickle.TupleCodec

  @time_sig {:time_sig, [:bar, {:sig, [:num, :den]}]}

  describe "dump/2" do
    test "zips a tuple tree into a map tree" do
      assert TupleCodec.dump({1, {4, 4}}, @time_sig) == %{bar: 1, sig: %{num: 4, den: 4}}
    end

    test "output is pickle-conform" do
      assert_pickle_conform(TupleCodec.dump({1, {4, 4}}, @time_sig))
    end

    test "shape mismatch raises (programmer error)" do
      assert_raise ArgumentError, ~r/invalid pair shape/, fn ->
        TupleCodec.dump({1, 2, 3}, {:pair, [:a, :b]})
      end

      assert_raise ArgumentError, ~r/invalid pair shape/, fn ->
        # 经 apply/3 调用：类型检查器无法证出必然 raise（那正是被测行为）
        apply(TupleCodec, :dump, [[1, 2], {:pair, [:a, :b]}])
      end
    end
  end

  describe "load/2" do
    test "parses a map tree back into the tuple tree" do
      assert {:ok, {1, {4, 4}}} = TupleCodec.load(%{bar: 1, sig: %{num: 4, den: 4}}, @time_sig)
    end

    test "round-trips with dump/2" do
      dumped = TupleCodec.dump({1, {4, 4}}, @time_sig)
      assert {:ok, {1, {4, 4}}} = TupleCodec.load(dumped, @time_sig)
    end

    test "non-map input is an error tagged with the schema name" do
      assert {:error, {:invalid_time_sig_dump, [1, [4, 4]]}} =
               TupleCodec.load([1, [4, 4]], @time_sig)
    end

    test "missing key is an error" do
      assert {:error, {:invalid_time_sig_dump, %{bar: 1}}} = TupleCodec.load(%{bar: 1}, @time_sig)
    end

    test "extra key is an error (strict)" do
      bad = %{bar: 1, sig: %{num: 4, den: 4}, extra: true}
      assert {:error, {:invalid_time_sig_dump, ^bad}} = TupleCodec.load(bad, @time_sig)
    end

    test "nested shape errors carry the nested schema's own tag" do
      assert {:error, {:invalid_sig_dump, %{num: 4}}} =
               TupleCodec.load(%{bar: 1, sig: %{num: 4}}, @time_sig)
    end
  end
end
