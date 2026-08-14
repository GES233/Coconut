defmodule Coconut.Pickle.Workspace do
  @moduledoc """
  `Coconut.Edit.Workspace` 的原生对象 codec（arity-2：`dump/2` / `load/2`）。

  与 `Coconut.Pickle.Track` 一样不实现 `Coconut.Pickle` behaviour——
  需要注入 registry 的 codec 用 arity-2 同风格签名。

  dump 为摊平的 map：

  - `id` / `edit_version` / `tpqn` 原样直出；
  - `tracks` / `globals` 两个 map 的键（track id）直出，每个 value 走
    `Coconut.Pickle.Track` codec；
  - `time_sigs` 是 `[{bar, {num, den}}]`，经 `Coconut.Pickle.TupleCodec`
    转为语义 map 列表 `[%{bar: _, sig: %{num: _, den: _}}, ...]`，
    load 反向解析回 tuple。

  load 还原后经 `Coconut.Edit.Workspace.new/1` 重建——`validate/1` 自然生效：
  全局轨命名空间、tempo 槽位能力、time_sigs 合法性都会被复检。
  """

  alias Coconut.Edit.Workspace
  alias Coconut.Pickle.{Registry, Struct, Track}

  @time_sig {:time_sig, [:bar, {:sig, [:num, :den]}]}

  @fields [
    :id,
    :edit_version,
    {:tracks, {:map_values, {:codec, Track, :with_ctx}}},
    {:globals, {:map_values, {:codec, Track, :with_ctx}}},
    :tpqn,
    :frame_rate,
    {:time_sigs, {:list, {:tuple, @time_sig}}}
  ]

  @doc "把 `Coconut.Edit.Workspace` 摊平为仅含允许类型的 plain map。"
  @spec dump(Workspace.t(), Registry.t()) :: {:ok, map()} | {:error, term()}
  def dump(ws, %Registry{} = registry), do: Struct.dump(Workspace, ws, @fields, registry)

  @doc "从 plain map 重建 `Coconut.Edit.Workspace`（经 `Workspace.new/1`，校验生效）。"
  @spec load(map(), Registry.t()) :: {:ok, Workspace.t()} | {:error, term()}
  def load(data, %Registry{} = registry), do: Struct.load(Workspace, data, @fields, registry)
end
