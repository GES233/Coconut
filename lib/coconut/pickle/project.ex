defmodule Coconut.Pickle.Project do
  @moduledoc """
  `Coconut.Project` 的原生对象 codec（arity-2：`dump/2` / `load/2`）。

  与 Track/Workspace codec 一样不实现 `Coconut.Pickle` behaviour——需要
  注入 registry 的 codec 用 arity-2 同风格签名，registry 透传给
  `Coconut.Pickle.Workspace`。

  dump 为摊平的 map：

  - `id` 原样直出；
  - `workspace` 走 `Coconut.Pickle.Workspace` codec；
  - `voicebank` 签名三元组 `%{name, engine, digest}` 直出（三键都是允许
    类型），load 经 `Project.new/1` 校验形状；
  - `metadata` 裸 map 原样透传，但 dump/load 两侧都须满足
    `Coconut.Pickle` 允许类型约定（对照 `Note.metadata` 契约），否则
    `{:error, {:non_conform_metadata, _}}`。

  字段规格驱动（`Coconut.Pickle.Struct`）；load 还原后经
  `Coconut.Project.new/1` 重建（workspace、voicebank 形状校验生效）。
  v1 旧档中的 `engine` / `settings` / `assets` nil 字段会被忽略；
  非 nil 值仍按旧契约拒绝。
  """

  alias Coconut.Pickle.{Registry, Struct, Workspace}
  alias Coconut.Project

  @fields [
    :id,
    {:workspace, {:codec, Workspace, :with_ctx}},
    :voicebank,
    {:metadata, {:conform, :non_conform_metadata}}
  ]

  @legacy_fields [:engine, :settings, :assets]

  @doc "把 `Coconut.Project` 摊平为仅含允许类型的 plain map。"
  @spec dump(Project.t(), Registry.t()) :: {:ok, map()} | {:error, term()}
  def dump(project, %Registry{} = registry), do: Struct.dump(Project, project, @fields, registry)

  @doc "从 plain map 重建 `Coconut.Project`（经 `Project.new/1`，校验生效）。"
  @spec load(map(), Registry.t()) :: {:ok, Project.t()} | {:error, term()}
  def load(data, %Registry{} = registry) when is_map(data) do
    with :ok <- check_legacy_fields(data) do
      Struct.load(Project, data, @fields, registry)
    end
  end

  def load(data, %Registry{} = registry), do: Struct.load(Project, data, @fields, registry)

  defp check_legacy_fields(data) do
    case Enum.find(@legacy_fields, &(Map.get(data, &1) != nil)) do
      nil -> :ok
      field -> {:error, {:reserved_field_set, field}}
    end
  end
end
