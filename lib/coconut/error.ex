defmodule Coconut.Error do
  @moduledoc """
  壳/接口层的错误包装工具。

  库内部全链路使用裸 reason——`invalid_*`（值形状非法）/ `unknown_*`
  （id/引用查无此物）/ `missing_*`（必需物缺席）三家语义的 atom 或
  tuple，lib 内任何模块都不调用本模块。

  本模块留给对外边界使用：未来 GenServer 壳 / JSON-RPC 接口在对外
  序列化之前，或 sibling 包在自己的边界上，把裸 reason 包进本结构体
  （`wrap/1`），需要还原时用 `unwrap/1`。

  同时是 exception，必要时可直接 `raise`。
  """

  @type t :: %__MODULE__{reason: term()}

  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: reason}), do: "coconut error: #{inspect(reason)}"

  @doc """
  把 `{:error, reason}` 包成 `{:error, %Coconut.Error{}}`；已包装的幂等
  透传，非 error 的值原样返回。
  """
  @spec wrap({:error, term()}) :: {:error, t()}
  @spec wrap(other) :: other when other: term()
  def wrap({:error, %__MODULE__{}} = wrapped), do: wrapped
  def wrap({:error, reason}), do: {:error, %__MODULE__{reason: reason}}
  def wrap(other), do: other

  @doc """
  `wrap/1` 的逆操作：取出裸 reason；非包装值原样返回。
  """
  @spec unwrap({:error, t()}) :: {:error, term()}
  @spec unwrap(other) :: other when other: term()
  def unwrap({:error, %__MODULE__{reason: reason}}), do: {:error, reason}
  def unwrap(other), do: other
end
