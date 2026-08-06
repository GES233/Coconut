defmodule Coconut.Pickle.Project do
  @moduledoc """
  `Coconut.Project` 的原生对象 codec（arity-2：`dump/2` / `load/2`）。

  与 Track/Workspace codec 一样不实现 `Coconut.Pickle` behaviour——需要
  注入 registry 的 codec 用 arity-2 同风格签名，registry 透传给
  `Coconut.Pickle.Workspace`。

  dump 为摊平的 map：

  - `id` 原样直出；
  - `workspace` 走 `Coconut.Pickle.Workspace` codec；
  - `engine` / `settings` / `assets` 保留字段原样透传（v1 一律 nil，
    `Project.validate/1` 保证非 nil 进不来）；
  - `voicebank` 签名三元组 `%{name, engine, digest}` 直出（三键都是允许
    类型），load 经 `Project.new/1` 校验形状；
  - `metadata` 裸 map 原样透传，但 dump/load 两侧都须满足
    `Coconut.Pickle` 允许类型约定（对照 `Note.metadata` 契约），否则
    `{:error, {:non_conform_metadata, _}}`。

  load 还原后经 `Coconut.Project.new/1` 重建（保留字段、voicebank 形状
  校验生效）。
  """

  alias Coconut.Pickle.{Registry, Workspace}
  alias Coconut.Project
  import Coconut.Pickle

  @doc "把 `Coconut.Project` 摊平为仅含允许类型的 plain map。"
  @spec dump(Project.t(), Registry.t()) :: {:ok, map()} | {:error, term()}
  def dump(%Project{} = project, %Registry{} = registry) do
    with {:ok, workspace} <- Workspace.dump(project.workspace, registry),
         :ok <- check_conform_metadata(project.metadata) do
      {:ok,
       %{
         id: project.id,
         workspace: workspace,
         engine: project.engine,
         settings: project.settings,
         assets: project.assets,
         voicebank: project.voicebank,
         metadata: project.metadata
       }}
    end
  end

  def dump(other, %Registry{}), do: {:error, {:invalid_project, other}}

  @doc "从 plain map 重建 `Coconut.Project`（经 `Project.new/1`，校验生效）。"
  @spec load(map(), Registry.t()) :: {:ok, Project.t()} | {:error, term()}
  def load(%{} = data, %Registry{} = registry) do
    with {:ok, workspace} <- load_workspace(Map.get(data, :workspace), registry),
         :ok <- check_conform_metadata(Map.get(data, :metadata)) do
      %{
        id: Map.get(data, :id),
        workspace: workspace,
        engine: Map.get(data, :engine),
        settings: Map.get(data, :settings),
        assets: Map.get(data, :assets),
        voicebank: Map.get(data, :voicebank),
        metadata: Map.get(data, :metadata)
      }
      |> Project.new()
    end
  end

  def load(other, %Registry{}), do: {:error, {:invalid_project_dump, other}}

  defp load_workspace(%{} = dumped, registry), do: Workspace.load(dumped, registry)

  defp load_workspace(other, _registry), do: {:error, {:invalid_workspace_dump, other}}

  # metadata 原样透传，但须满足 Coconut.Pickle 的允许类型约定
  # （与 Track codec 对 dead reason 的处理同一做法）
  defp check_conform_metadata(metadata) do
    if pickle_conform?(metadata), do: :ok, else: {:error, {:non_conform_metadata, metadata}}
  end
end
