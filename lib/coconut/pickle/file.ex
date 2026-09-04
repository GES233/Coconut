defmodule Coconut.Pickle.File do
  @moduledoc """
  工程文件外壳：`%{format, version, project, history}` 版本信封 +
  `:erlang.term_to_binary/1` 落盘。

  - `write/4`：`Coconut.Pickle.Project.dump` + 可选
    `Coconut.Pickle.History.dump`（`opts[:history]`）→ 包信封
    `%{format: :coconut_project, version: 2, project: dumped, history: dumped | nil}`
    → `term_to_binary` → `File.write/2`；
  - `read/2`：`File.read` → `binary_to_term` → 校验 `format` 标签与
    `version`（未知版本报 `{:error, {:unsupported_format_version, v}}`，
    是将来格式迁移的钩子）→ `Coconut.Pickle.Project.load`，丢弃历史部分；
  - `read_with_history/2`：同上，但返回 `{:ok, project, history | nil}`——
    v1 旧档没有 `history` 字段，读入为 `nil`（调用方开新鲜历史）。

  ## 安全立场（v1/v2）

  `binary_to_term/1` **不带 `[:safe]`**：工程文件视为可信本地文件。
  dump 里的 atom 都是 registry 白名单内的模块标签，但 `metadata` 等
  用户内容无法先验保证只含既有 atom，干脆约定可信输入。将来若要打开
  不可信文件，加固方向：换 `[:safe]` + 先把 metadata 等自由字段降为
  binary 键/值，或改走 JSON 信封（dump 产物本身已满足 JSON 可转换的
  类型约定）。
  """

  alias Coconut.Edit.History
  alias Coconut.Pickle.{Project, Registry}
  alias Coconut.Pickle.History, as: PickleHistory

  @format :coconut_project
  @version 2

  @doc """
  把工程 dump 后包版本信封落盘，返回 `{:ok, path}`。

  `opts[:history]` 给出时一并存档 undo/redo 历史（`Coconut.Edit.History`），
  其 present 必须与工程 workspace 一致（同一份会话状态的两次投影）。
  """
  @spec write(Coconut.Project.t(), Registry.t(), Path.t(), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def write(%Coconut.Project{} = project, %Registry{} = registry, path, opts \\ []) do
    with {:ok, dumped} <- Project.dump(project, registry),
         {:ok, history} <- dump_history(Keyword.get(opts, :history), registry),
         envelope = %{format: @format, version: @version, project: dumped, history: history},
         :ok <- File.write(path, :erlang.term_to_binary(envelope)) do
      {:ok, path}
    end
  end

  @doc "读回工程文件：解信封、校验 format/version，经 Project codec 重建（历史部分丢弃）。"
  @spec read(Path.t(), Registry.t()) :: {:ok, Coconut.Project.t()} | {:error, term()}
  def read(path, %Registry{} = registry) do
    with {:ok, project, _history} <- read_with_history(path, registry) do
      {:ok, project}
    end
  end

  @doc """
  同 `read/2`，但一并还原存档的 undo/redo 历史。

  v1 旧档无 `history` 字段，返回的 history 为 `nil`；调用方据此开新鲜
  历史（`History.new/2`）。
  """
  @spec read_with_history(Path.t(), Registry.t()) ::
          {:ok, Coconut.Project.t(), History.t() | nil} | {:error, term()}
  def read_with_history(path, %Registry{} = registry) do
    with {:ok, binary} <- File.read(path),
         {:ok, envelope} <- decode(binary),
         :ok <- check_envelope(envelope),
         {:ok, project} <- Project.load(envelope.project, registry),
         {:ok, history} <- load_history(Map.get(envelope, :history), registry) do
      {:ok, project, history}
    end
  end

  # 非 term_to_binary 产物（截断/损坏/非本格式文件）包装为 error tuple，不 raise
  defp decode(binary) do
    {:ok, :erlang.binary_to_term(binary)}
  rescue
    _ -> {:error, :invalid_file_contents}
  end

  defp check_envelope(%{format: @format, version: version})
       when version in [1, 2],
       do: :ok

  defp check_envelope(%{format: @format, version: version}),
    do: {:error, {:unsupported_format_version, version}}

  defp check_envelope(other), do: {:error, {:invalid_envelope, other}}

  defp dump_history(nil, _registry), do: {:ok, nil}
  defp dump_history(%History{} = history, registry), do: PickleHistory.dump(history, registry)
  defp dump_history(other, _registry), do: {:error, {:invalid_history, other}}

  defp load_history(nil, _registry), do: {:ok, nil}
  defp load_history(dumped, registry), do: PickleHistory.load(dumped, registry)
end
