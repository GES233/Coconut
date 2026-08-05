defmodule Coconut.Project do
  @moduledoc """
  工程（落盘单元）：一个 `Coconut.Workspace` 加上工程级的声库签名与
  自由元数据。

  ## 字段

  - `id` — 必需，同 Workspace/Note 的 id 纪律；
  - `workspace` — `Coconut.Workspace.t()`，编辑聚合本体；
  - `engine` — **保留**，v1 一律 `nil`（引擎与 Orchid 的边界未定）；
  - `settings` — **保留**，v1 一律 `nil`（引擎设置/globals 边界未定）；
  - `assets` — **保留**，v1 一律 `nil`（`Track.Audio` 未落地）；
  - `voicebank` — 声库签名三元组
    `%{name: binary, engine: atom, digest: binary} | nil`。digest 是声库
    内容哈希（加载时核对安装的声库是否匹配），v1 只存不算；
  - `metadata` — 裸 map，原样透传（须满足 `Coconut.Pickle` 的可序列化
    约定，对照 `Note.metadata` 契约）。

  保留字段非 nil 报错是刻意的：边界未定时不让数据先进格式，将来启用
  （定形状、定 codec）时放开 `validate/1` 的对应分支，旧档无需迁移。
  """

  alias Coconut.Workspace
  alias Coconut.Util.ID

  import Coconut.Helpers, only: [normalize_attrs: 2]

  @typedoc "声库签名：名称 + 引擎 + 内容哈希。"
  @type voicebank :: %{name: binary(), engine: atom(), digest: binary()}

  @type t :: %__MODULE__{
          id: ID.t(),
          workspace: Workspace.t(),
          engine: nil,
          settings: nil,
          assets: nil,
          voicebank: voicebank() | nil,
          metadata: map() | nil
        }

  @keys [:id, :workspace, :engine, :settings, :assets, :voicebank, :metadata]
  defstruct @keys

  @doc "Create a new project from the given attributes. `:id` must be provided explicitly."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, normalized} <- normalize_attrs(attrs, @keys) do
      case Map.fetch(normalized, :id) do
        :error ->
          {:error, {:missing_id, "Proj_"}}

        {:ok, id} ->
          __MODULE__
          |> struct(Map.put(normalized, :id, id))
          |> validate()
      end
    end
  end

  @doc """
  Construction-time legality: reserved fields must stay nil in v1, and
  `voicebank` must be the full signature triple.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = project) do
    cond do
      project.engine != nil ->
        {:error, {:reserved_field_set, :engine}}

      project.settings != nil ->
        {:error, {:reserved_field_set, :settings}}

      project.assets != nil ->
        {:error, {:reserved_field_set, :assets}}

      not valid_voicebank?(project.voicebank) ->
        {:error, {:invalid_voicebank, project.voicebank}}

      true ->
        {:ok, project}
    end
  end

  defp valid_voicebank?(nil), do: true

  defp valid_voicebank?(%{name: name, engine: engine, digest: digest})
       when is_binary(name) and is_atom(engine) and is_binary(digest),
       do: true

  defp valid_voicebank?(_other), do: false
end
