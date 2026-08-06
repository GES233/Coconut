defmodule Coconut.PickleHelper do
  @moduledoc """
  Pickle codec 测试的共享断言。

  `assert_pickle_conform/1` 遍历 dump 产物，断言只含 `Coconut.Pickle`
  约定的允许类型：map / list / number / binary / atom / boolean / nil
  （map 键限 atom / binary / integer）；tuple / struct / fun / pid 一律 flunk。

  See `Coconut.Pickle.pickle_conform?/1`.
  """

  import ExUnit.Assertions

  @doc "断言 dump 产物满足 `Coconut.Pickle` 的允许类型约定。"
  def assert_pickle_conform(term) when is_map(term) and not is_struct(term) do
    Enum.each(term, fn {k, v} ->
      assert is_atom(k) or is_binary(k) or is_integer(k), "forbidden map key: #{inspect(k)}"
      assert_pickle_conform(v)
    end)
  end

  def assert_pickle_conform(term) when is_list(term),
    do: Enum.each(term, &assert_pickle_conform/1)

  def assert_pickle_conform(term)
      when is_number(term) or is_binary(term) or is_atom(term),
      do: :ok

  def assert_pickle_conform(term),
    do: flunk("forbidden term in pickle dump: #{inspect(term)}")
end
