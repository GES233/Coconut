defmodule Coconut.Project do
  @moduledoc """
  工程（落盘单元）：一个 `Coconut.Edit.Workspace` 加上工程级的声库签名与
  自由元数据。

  ## 字段

  - `id` — 必需，同 Workspace/Note 的 id 纪律；
  - `workspace` — `Coconut.Edit.Workspace.t()`，编辑聚合本体；
  - `voicebank` — 声库签名三元组
    `%{name: binary, engine: atom, digest: binary} | nil`。digest 是声库
    内容哈希（加载时核对安装的声库是否匹配），v1 只存不算；
  - `metadata` — 裸 map，原样透传（须满足 `Coconut.Pickle` 的可序列化
    约定，对照 `Note.metadata` 契约）。

  v1 旧档中的 `engine` / `settings` / `assets` 由 Pickle codec
  兼容读取，不进入领域 struct。
  """

  alias Coconut.Edit.Workspace
  alias Coconut.Util.ID

  import Coconut.Util.Helpers, only: [strictly_normalize_attrs: 2]

  @typedoc "声库签名：名称 + 引擎 + 内容哈希。"
  @type voicebank :: %{name: binary(), engine: atom(), digest: binary()}

  @type t :: %__MODULE__{
          id: ID.t(),
          workspace: Workspace.t(),
          voicebank: voicebank() | nil,
          metadata: map() | nil
        }

  @keys [:id, :workspace, voicebank: nil, metadata: nil]
  defstruct @keys

  @doc "Create a new project from the given attributes. `:id` must be provided explicitly."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, normalized} <- strictly_normalize_attrs(attrs, @keys) do
      case Map.fetch(normalized, :id) do
        :error ->
          {:error, {:missing_id, "Proj_"}}

        {:ok, id} ->
          project = %__MODULE__{
            id: id,
            workspace: Map.get(normalized, :workspace),
            voicebank: Map.get(normalized, :voicebank),
            metadata: Map.get(normalized, :metadata)
          }

          validate(project)
      end
    end
  end

  @doc """
  Construction-time legality: workspace is required and valid, and
  `voicebank` must be the full signature triple.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = project) do
    cond do
      not match?(%Workspace{}, project.workspace) ->
        {:error, {:invalid_workspace, project.workspace}}

      not valid_voicebank?(project.voicebank) ->
        {:error, {:invalid_voicebank, project.voicebank}}

      true ->
        case Workspace.validate(project.workspace) do
          {:ok, _workspace} -> {:ok, project}
          {:error, _} = error -> error
        end
    end
  end

  defp valid_voicebank?(nil), do: true

  defp valid_voicebank?(%{name: name, engine: engine, digest: digest})
       when is_binary(name) and is_atom(engine) and is_binary(digest),
       do: true

  defp valid_voicebank?(_other), do: false
end
