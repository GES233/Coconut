defmodule Coconut.Pickle.Registry do
  @moduledoc """
  name ↔ module 的双向映射，供需要模块标签的 codec（`Coconut.Pickle.Track`
  等）把 dump 里的模块 atom 换成逻辑名。

  动机：

  - 模块名是代码布局，不是领域概念——存档里写逻辑名（`"vocal"`），
    代码重构改名时旧档仍可 load（改名弹性）；
  - load 侧闭白名单：只有注册过的名字能还原成模块，不注册的名字直接
    error，杜绝任意 atom 注入（原子安全）；
  - 格式对非 BEAM 消费方中立：逻辑名不绑定 Elixir 模块命名。

  纯数据、无进程状态：registry 由调用方显式传入 codec，不藏全局状态。

  ## codec 绑定（可选）

  每个注册项可额外绑定一个 `Coconut.Pickle.ElementCodec` 模块——该轨型的
  元素级归档 codec（`Coconut.Pickle.Track` 存取 `elements_by_id` 时按它逐元素
  委托）。绑定随注册走（`new/1` 的 `{module, codec}` 形状或
  `register/4` 的 `codec:` 选项），不绑定的轨型只能归档空元素表。
  """

  @type t :: %__MODULE__{
          by_name: %{binary() => module()},
          by_module: %{module() => binary()},
          codec_by_module: %{module() => module()},
          track_by_element: %{module() => module()}
        }

  defstruct by_name: %{}, by_module: %{}, codec_by_module: %{}, track_by_element: %{}

  @doc """
  从 `%{name => module}` 建 registry（`%{}` 建空表）。

  映射值也接受 `{module, codec}` 形状，为该注册项绑定元素 codec（见
  「codec 绑定」一节）。

  映射内模块重复（两个名字指向同一模块）报 `{:error, {:module_taken, _}}`。
  """
  @spec new(%{binary() => module() | {module(), module()}}) :: {:ok, t()} | {:error, term()}
  def new(mapping \\ %{}) when is_map(mapping) do
    Enum.reduce_while(mapping, {:ok, %__MODULE__{}}, fn {name, value}, {:ok, registry} ->
      {module, opts} =
        case value do
          {module, codec} -> {module, [codec: codec]}
          module -> {module, []}
        end

      case register(registry, name, module, opts) do
        {:ok, registry} -> {:cont, {:ok, registry}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc """
  注册一对 name ↔ module，返回新 registry。

  选项：`:codec` — 该轨型的 `Coconut.Pickle.ElementCodec` 模块（可选，
  见「codec 绑定」一节）。

  名字已被占用报 `{:error, {:name_taken, name}}`；
  模块已注册（别名）报 `{:error, {:module_taken, module}}`。
  """
  @spec register(t(), binary(), module(), keyword()) :: {:ok, t()} | {:error, term()}
  def register(%__MODULE__{} = registry, name, module, opts \\ [])
      when is_binary(name) and is_atom(module) do
    codec = Keyword.get(opts, :codec)

    cond do
      Map.has_key?(registry.by_name, name) ->
        {:error, {:name_taken, name}}

      Map.has_key?(registry.by_module, module) ->
        {:error, {:module_taken, module}}

      # nil is atom
      not is_atom(codec) ->
        {:error, {:invalid_codec, codec}}

      true ->
        {:ok,
         %{
           registry
           | by_name: Map.put(registry.by_name, name, module),
             by_module: Map.put(registry.by_module, module, name),
             codec_by_module: maybe_put_codec(registry.codec_by_module, module, codec),
             track_by_element: maybe_index_element(registry.track_by_element, module, codec)
         }}
    end
  end

  defp maybe_put_codec(codec_by_module, _module, nil), do: codec_by_module

  defp maybe_put_codec(codec_by_module, module, codec),
    do: Map.put(codec_by_module, module, codec)

  # codec 声明了 element_module/0 才建立 元素模块 → 轨型 索引
  # （裸 map 元素的轨型不声明，归档按 plain 数据透传）。
  defp maybe_index_element(track_by_element, _module, nil), do: track_by_element

  defp maybe_index_element(track_by_element, module, codec) do
    if Code.ensure_loaded?(codec) and function_exported?(codec, :element_module, 0) do
      Map.put(track_by_element, codec.element_module(), module)
    else
      track_by_element
    end
  end

  @doc "模块 → 逻辑名；未注册报 `{:error, {:unregistered_module, module}}`。"
  @spec to_name(t(), module()) :: {:ok, binary()} | {:error, {:unregistered_module, module()}}
  def to_name(%__MODULE__{by_module: by_module}, module) when is_atom(module) do
    case Map.fetch(by_module, module) do
      {:ok, name} -> {:ok, name}
      :error -> {:error, {:unregistered_module, module}}
    end
  end

  @doc "逻辑名 → 模块；未知名报 `{:error, {:unknown_type_name, name}}`。"
  @spec to_module(t(), binary()) :: {:ok, module()} | {:error, {:unknown_type_name, binary()}}
  def to_module(%__MODULE__{by_name: by_name}, name) when is_binary(name) do
    case Map.fetch(by_name, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_type_name, name}}
    end
  end

  @doc """
  模块 → 绑定的元素 codec；未绑定报 `{:error, {:missing_element_codec, module}}`
  （未注册的模块同此报错——没注册自然没有绑定）。
  """
  @spec to_codec(t(), module()) :: {:ok, module()} | {:error, {:missing_element_codec, module()}}
  def to_codec(%__MODULE__{codec_by_module: codec_by_module}, module) when is_atom(module) do
    case Map.fetch(codec_by_module, module) do
      {:ok, codec} -> {:ok, codec}
      :error -> {:error, {:missing_element_codec, module}}
    end
  end

  @doc """
  元素 struct 模块 → `{轨型逻辑名, 元素 codec}`。

  供无轨道上下文的归档分派（History record 的 `:batch` side_changes 只有
  track_id，元素按 `__struct__` 反查）。轨型 codec 未声明
  `element_module/0`（裸 map 元素）报
  `{:error, {:unregistered_element_module, _}}`。
  """
  @spec to_element_codec(t(), module()) ::
          {:ok, {binary(), module()}} | {:error, {:unregistered_element_module, module()}}
  def to_element_codec(%__MODULE__{} = registry, element_module) when is_atom(element_module) do
    with {:ok, track_module} <- fetch_element(registry, element_module),
         {:ok, codec} <- to_codec(registry, track_module),
         {:ok, name} <- to_name(registry, track_module) do
      {:ok, {name, codec}}
    end
  end

  defp fetch_element(registry, element_module) do
    case Map.fetch(registry.track_by_element, element_module) do
      {:ok, track_module} -> {:ok, track_module}
      :error -> {:error, {:unregistered_element_module, element_module}}
    end
  end
end
