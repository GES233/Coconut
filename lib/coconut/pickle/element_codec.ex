defmodule Coconut.Pickle.ElementCodec do
  @moduledoc """
  元素级归档 codec：把一条 track 的元素载荷摊平为仅含
  `Coconut.Pickle` 允许类型的 plain 数据（`dump_element/1`），以及反向重建
  （`load_element/1`）。

  codec 经 `Coconut.Pickle.Registry` 绑定到轨型模块（注册项的可选 `codec`
  项）；`Coconut.Pickle.Track` 存取档时按 registry 解析并逐元素委托。
  注册项未绑定 codec 且元素表非空时，归档报
  `{:error, {:missing_element_codec, module}}`。
  """

  @callback dump_element(element :: term()) :: {:ok, term()} | {:error, term()}
  @callback load_element(dumped :: term()) :: {:ok, term()} | {:error, term()}

  @doc """
  该 codec 处理的元素 struct 模块（可选）。

  声明后 `Coconut.Pickle.Registry` 建立 元素模块 → 轨型 索引，供无轨道
  上下文的 codec 分派（History record 的 `:batch` side_changes 只有
  track_id 没有轨型，元素按 `__struct__` 反查 codec）。元素是裸 map 的
  轨型（如 Tempo）不声明——裸 map 元素在归档时按 plain 数据透传。
  """
  @callback element_module() :: module()

  @optional_callbacks element_module: 0
end
