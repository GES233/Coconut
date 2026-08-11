defmodule Coconut.ErrorTest do
  use ExUnit.Case, async: true

  alias Coconut.Error

  describe "wrap/1" do
    test "wraps a bare reason" do
      assert {:error, %Error{reason: :missing_tempo_track}} =
               Error.wrap({:error, :missing_tempo_track})
    end

    test "is idempotent on an already-wrapped error" do
      wrapped = {:error, %Error{reason: {:unknown_track, "nope"}}}
      assert Error.wrap(wrapped) == wrapped
    end

    test "passes non-error values through" do
      assert Error.wrap({:ok, 42}) == {:ok, 42}
      assert Error.wrap(:ok) == :ok
    end
  end

  describe "unwrap/1" do
    test "round-trips with wrap/1" do
      reason = {:invalid_time_sigs, []}

      assert {:error, reason} |> Error.wrap() |> Error.unwrap() == {:error, reason}
    end

    test "passes non-wrapped values through" do
      assert Error.unwrap({:error, :bare}) == {:error, :bare}
      assert Error.unwrap({:ok, 42}) == {:ok, 42}
    end
  end

  describe "message/1" do
    test "renders the reason" do
      assert Exception.message(%Error{reason: :missing_tempo_track}) ==
               "coconut error: :missing_tempo_track"
    end

    test "is raisable as an exception" do
      assert_raise Error, "coconut error: :enoent", fn ->
        raise Error, reason: :enoent
      end
    end
  end
end
