defmodule Coconut.Scenarios.GInt01 do
  @moduledoc """
  G-INT-01（coconut 版）：split 对抗 — patch 存活于左半，digest 仍 resolve。

  与 zongzi 原版的设计差异（在此钉成验收点）：zongzi 靠 split_hint 把
  一个 intervention 裂成两个子干预；coconut 的 `%Split{children: [id, new_id]}`
  保留左 id，写时 transport 后 patch 存活在左半，右半天然不被覆盖 ——
  不复制、不分裂。
  """
  @behaviour Coconut.Scenario

  import Coconut.Scenario,
    only: [base_workspace: 0, insert_note: 5, mount_note_patch: 4, default_channels: 0]

  @impl true
  def id, do: "G-INT-01"
  @impl true
  def title, do: "split 后 patch 存活于左半且 resolve（右半无 patch）"

  @impl true
  def setup do
    ws =
      base_workspace()
      |> insert_note("n1", :head, {0, 480}, %{pitch: 62})
      |> insert_note("n2", "n1", {480, 960}, %{pitch: 62})
      |> insert_note("n3", "n2", {960, 1440}, %{pitch: 62})
      |> mount_note_patch("n2", :lyric, %{lyric: "らん"})

    {ws, default_channels()}
  end

  @impl true
  def edits(_ws),
    do: [
      %Coconut.Edit.Operations.SplitNote{
        track_id: "vocal",
        note_id: "n2",
        at_tick: 720,
        new_id: "n2_b"
      }
    ]

  @impl true
  def expect(%{rounds: [baseline, r1], final_ws: final_ws}) do
    cond do
      not baseline.passed ->
        {:miss, "baseline 应通过，实际 entries #{inspect(baseline.entries)}"}

      length(baseline.survivors) != 1 ->
        {:miss, "baseline 应有 1 个存活 patch，实际 #{inspect(baseline.survivors)}"}

      not r1.passed ->
        {:miss, "split 后 digest 仍应 resolve，实际 entries #{inspect(r1.entries)}"}

      r1.dead != [] ->
        {:miss, "split 不应产生死 patch，实际 #{inspect(r1.dead)}"}

      anchor_refs(r1.survivors) != [["n2"]] ->
        {:miss, "patch 应锚在左半 n2 且不复制，实际 #{inspect(anchor_refs(r1.survivors))}"}

      "n2_b" not in final_ws.tracks["vocal"].space.ids ->
        {:miss, "右半 n2_b 应存在"}

      true ->
        :ok
    end
  end

  defp anchor_refs(survivors) do
    Enum.map(survivors, fn %{anchor: %Tamale.Anchor.Ordinal{refs: refs}} -> refs end)
  end
end
