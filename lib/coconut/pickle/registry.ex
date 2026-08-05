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
  """

  @type t :: %__MODULE__{by_name: %{binary() => module()}, by_module: %{module() => binary()}}

  defstruct by_name: %{}, by_module: %{}

  @doc """
  从 `%{name => module}` 建 registry（`%{}` 建空表）。

  映射内模块重复（两个名字指向同一模块）报 `{:error, {:module_taken, _}}`。
  """
  @spec new(%{binary() => module()}) :: {:ok, t()} | {:error, term()}
  def new(mapping \\ %{}) when is_map(mapping) do
    Enum.reduce_while(mapping, {:ok, %__MODULE__{}}, fn {name, module}, {:ok, registry} ->
      case register(registry, name, module) do
        {:ok, registry} -> {:cont, {:ok, registry}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc """
  注册一对 name ↔ module，返回新 registry。

  名字已被占用报 `{:error, {:name_taken, name}}`；
  模块已注册（别名）报 `{:error, {:module_taken, module}}`。
  """
  @spec register(t(), binary(), module()) :: {:ok, t()} | {:error, term()}
  def register(%__MODULE__{} = registry, name, module)
      when is_binary(name) and is_atom(module) do
    cond do
      Map.has_key?(registry.by_name, name) ->
        {:error, {:name_taken, name}}

      Map.has_key?(registry.by_module, module) ->
        {:error, {:module_taken, module}}

      true ->
        {:ok,
         %{
           registry
           | by_name: Map.put(registry.by_name, name, module),
             by_module: Map.put(registry.by_module, module, name)
         }}
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
end
