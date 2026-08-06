defmodule Coconut.Scenarios.GInt02 do
  @moduledoc """
  G-INT-02：内容编辑 → base_digest 失配 → conflict，不静默 apply。

  与 zongzi 原版几乎一比一：`edit_note` 改了 patch 锚定元素的内容，
  `Resolve.run_check` 的 fresh base 与 `base_digest` 不符 → `:conflict`
  否决整批；结构未动，patch 不进坟场。
  """
  @behaviour Coconut.Scenario

  import Coconut.Scenario,
    only: [base_workspace: 0, insert_note: 5, mount_note_patch: 4, default_channels: 0]

  @impl true
  def id, do: "G-INT-02"
  @impl true
  def title, do: "内容编辑 → digest 失配 → conflict（不静默 apply）"

  @impl true
  def setup do
    ws =
      base_workspace()
      |> insert_note("n1", :head, {0, 480}, %{pitch: 62})
      |> insert_note("n2", "n1", {480, 960}, %{pitch: 62})
      |> mount_note_patch("n2", :lyric, %{lyric: "らん"})

    {ws, default_channels()}
  end

  # edit_note 的 changes 部分合并到现 element 上：pitch 62→65，其余不动。
  @impl true
  def edits(_ws),
    do: [
      %Coconut.Edit.Operations.EditNote{
        track_id: "vocal",
        note_id: "n2",
        changes: %{pitch: 65}
      }
      # {:edit_note, "vocal", "n2", %{pitch: 65}}
    ]

  @impl true
  def expect(%{rounds: [baseline, r1]}) do
    cond do
      not baseline.passed ->
        {:miss, "baseline 应通过，实际 entries #{inspect(baseline.entries)}"}

      r1.passed ->
        {:miss, "内容失配后不应再 apply（不静默），实际 passed"}

      r1.dead != [] ->
        {:miss, "结构未动，不应有死 patch，实际 #{inspect(r1.dead)}"}

      conflict_kinds(r1.entries) != [:conflict] ->
        {:miss, "应恰好一个 :conflict，实际 #{inspect(r1.entries)}"}

      true ->
        :ok
    end
  end

  defp conflict_kinds(entries), do: Enum.map(entries, & &1.kind)
end
