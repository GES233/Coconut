defmodule Coconut.Pickle.ElementCodec do
  @moduledoc """
  元素级归档 codec：把一条 track 的元素载荷摊平为仅含
  `Coconut.Pickle` 允许类型的 plain 数据（`dump_element/1`），以及反向重建
  （`load_element/1`）。

  codec 经 `Coconut.Pickle.Registry` 绑定到轨型模块（注册项的可选 `codec`
  项）；`Coconut.Pickle.Track` 存取档时按 registry 解析并逐元素委托。
  注册项未绑定 codec 且元素表非空时，归档报
  `{:error, {:no_element_codec, module}}`。
  """

  @callback dump_element(element :: term()) :: {:ok, term()} | {:error, term()}
  @callback load_element(dumped :: term()) :: {:ok, term()} | {:error, term()}
end
