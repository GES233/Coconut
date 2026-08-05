defmodule Coconut.Pickle.File do
  @moduledoc """
  工程文件外壳：`%{format, version, project}` 版本信封 +
  `:erlang.term_to_binary/1` 落盘。

  - `write/3`：`Coconut.Pickle.Project.dump` → 包信封
    `%{format: :coconut_project, version: 1, project: dumped}` →
    `term_to_binary` → `File.write/2`；
  - `read/2`：`File.read` → `binary_to_term/1` → 校验 `format` 标签与
    `version`（未知版本报 `{:error, {:unsupported_format_version, v}}`，
    是将来格式迁移的钩子）→ `Coconut.Pickle.Project.load`。

  ## 安全立场（v1）

  `binary_to_term/1` **不带 `[:safe]`**：工程文件视为可信本地文件。
  dump 里的 atom 都是 registry 白名单内的模块标签，但 `metadata` 等
  用户内容无法先验保证只含既有 atom，干脆约定可信输入。将来若要打开
  不可信文件，加固方向：换 `[:safe]` + 先把 metadata 等自由字段降为
  binary 键/值，或改走 JSON 信封（dump 产物本身已满足 JSON 可转换的
  类型约定）。
  """

  alias Coconut.Pickle.{Project, Registry}

  @format :coconut_project
  @version 1

  @doc "把工程 dump 后包版本信封落盘，返回 `{:ok, path}`。"
  @spec write(Coconut.Project.t(), Registry.t(), Path.t()) ::
          {:ok, Path.t()} | {:error, term()}
  def write(%Coconut.Project{} = project, %Registry{} = registry, path) do
    with {:ok, dumped} <- Project.dump(project, registry),
         envelope = %{format: @format, version: @version, project: dumped},
         :ok <- File.write(path, :erlang.term_to_binary(envelope)) do
      {:ok, path}
    end
  end

  @doc "读回工程文件：解信封、校验 format/version，经 Project codec 重建。"
  @spec read(Path.t(), Registry.t()) :: {:ok, Coconut.Project.t()} | {:error, term()}
  def read(path, %Registry{} = registry) do
    with {:ok, binary} <- File.read(path),
         {:ok, envelope} <- decode(binary),
         :ok <- check_envelope(envelope) do
      Project.load(envelope.project, registry)
    end
  end

  # 非 term_to_binary 产物（截断/损坏/非本格式文件）包装为 error tuple，不 raise
  defp decode(binary) do
    {:ok, :erlang.binary_to_term(binary)}
  rescue
    _ -> {:error, :invalid_file_contents}
  end

  defp check_envelope(%{format: @format, version: @version}), do: :ok

  defp check_envelope(%{format: @format, version: version}),
    do: {:error, {:unsupported_format_version, version}}

  defp check_envelope(other), do: {:error, {:invalid_envelope, other}}
end
