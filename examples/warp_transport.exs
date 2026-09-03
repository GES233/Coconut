# Example: warp segment transport
#
# Demonstrates the v1 non-ripple warp semantics (design doc §5): how Metric
# anchors travel when notes are retimed or deleted.
#
#   Retime  → the note's own span becomes a linear warp segment (op-carried)
#   Delete  → the note's span becomes a hole (no image)
#   others  → identity
#
# Anchors that cannot survive coherently die loudly — never silently
# misplace. Write-time transport: every apply_batch folds the fresh log
# entry and persists up-to-date anchors; the dead move to the graveyard
# (track.dead_patches) for the policy layer. The explicit transport calls
# below therefore re-fold nothing — they just re-verify the persisted state.

alias Coconut.Edit.{Operation, Patch, Track, WarpProvider, Workspace}
alias Coconut.Render.Resolve
alias Coconut.Util.ID
alias Tamale.Warp

defmodule Coconut.Examples.WarpChannel do
  @behaviour Coconut.Render.Channel

  alias Coconut.Edit.{Patch, Track}

  @impl true
  def projection(ws, %Patch{track_id: track_id, anchor: %Tamale.Anchor.Metric{} = anchor}) do
    from_tick = to_tick(anchor.from)
    to_tick = to_tick(anchor.to)

    overlapping =
      for {id, {start_tick, end_tick}} <- Track.latest_spans(ws.tracks[track_id]),
          start_tick < to_tick and end_tick > from_tick,
          into: %{} do
        element = Map.get(ws.tracks[track_id].elements_by_id, id)
        {id, canonicalize(element)}
      end

    {:ok, overlapping}
  end

  @impl true
  def target(%Patch{channel: channel}), do: {:port, :synth, channel}

  defp canonicalize(%Coconut.Score.Note{} = note), do: Coconut.Score.Note.to_canonical(note)
  defp canonicalize(other), do: other
  defp to_tick({numerator, denominator}), do: div(numerator, denominator)
  defp to_tick(tick) when is_integer(tick), do: tick
end

cfg = %Operation.Config{}
track = "vocal"

# ---- helpers ----

fmt = fn
  {n, 1} -> "#{n}"
  {n, d} -> "#{n}/#{d}"
  i when is_integer(i) -> "#{i}"
end

show_pieces = fn %Warp{pieces: pieces} ->
  Enum.each(pieces, fn {o0, o1, n0, n1} ->
    IO.puts("    old [#{fmt.(o0)}, #{fmt.(o1)}]  ->  new [#{fmt.(n0)}, #{fmt.(n1)}]")
  end)
end

transport_and_report = fn ws, label ->
  wp = WarpProvider.tick(Track.spans(ws.tracks[track]), ws.tracks[track].patches)
  {:ok, survivors, dead} = Track.transport_patches(ws.tracks[track], wp)

  IO.puts("\n=== #{label} ===")

  Enum.each(survivors, fn cp ->
    %Tamale.Anchor.Metric{from: f, to: t} = cp.anchor
    IO.puts("  survives  #{cp.channel}: [#{fmt.(f)}, #{fmt.(t)}]")
  end)

  Enum.each(dead, fn {cp, reason} ->
    IO.puts("  DIES      #{cp.channel}: #{inspect(reason)}")
  end)
end

# ---- 1. Bootstrap: one track, three adjacent notes ----
{:ok, tempo_track} = Track.new(%{id: "global:tempo", module: Track.Tempo})
{:ok, vocal_track} = Track.new(%{id: track, module: Track.Vocal})

{:ok, ws} =
  Workspace.new(%{
    id: ID.generate_id("WSpc_"),
    edit_version: 0,
    tracks: %{track => vocal_track},
    globals: %{"global:tempo" => tempo_track}
  })

notes = [
  {"n1", :head, {0, 480}, %{pitch: 60, lyric: "ら"}},
  {"n2", "n1", {480, 960}, %{pitch: 62, lyric: "り"}},
  {"n3", "n2", {960, 1440}, %{pitch: 64, lyric: "る"}}
]

ws =
  Enum.reduce(notes, ws, fn {id, after_id, span, attrs}, ws ->
    {:ok, ops, ch} =
      Operation.lower(
        %Coconut.Edit.Operations.InsertNote{
          track_id: track,
          note_id: id,
          after_id: after_id,
          span: span,
          attrs: attrs
        },
        ws,
        cfg
      )

    {:ok, ws} = Workspace.apply_batch(ws, track, ws.edit_version, ops, ch)
    ws
  end)

IO.puts("=== Setup ===")
IO.inspect(Track.latest_spans(ws.tracks[track]), label: "spans")

# ---- 2. Mount Metric patches (base digest captured at mount) ----
ver = ws.tracks[track].space.version

mount = fn from, to, channel, payload ->
  anchor = %Tamale.Anchor.Metric{coord: :tick, from: from, to: to, at_version: ver}
  probe = %Patch{track_id: track, anchor: anchor, channel: channel}
  {:ok, base} = Coconut.Examples.WarpChannel.projection(ws, probe)
  {:ok, tp} = Tamale.Patch.new(base, payload)
  {:ok, cp} = Patch.new(%{track_id: track, anchor: anchor, channel: channel, patch: tp})
  cp
end

patches = [
  mount.(120, 360, :energy, %{energy: 80}),
  mount.(500, 700, :vibrato, %{depth: 40}),
  mount.(1000, 1200, :curve, %{shape: :exp}),
  mount.(2100, 2200, :space, %{mark: true})
]

{:ok, ws, _minted} = Workspace.attach_patches(ws, patches)

IO.puts("\n=== Mounted at v#{ver} ===")
IO.puts("  energy  [120, 360]    on n1")
IO.puts("  vibrato [500, 700]    on n2")
IO.puts("  curve   [1000, 1200]  on n3")
IO.puts("  space   [2100, 2200]  past the end (empty space)")

# ---- 3. Act 1: drag n3 right into empty space ----
{:ok, ops, ch} =
  Operation.lower(
    %Coconut.Edit.Operations.DragNote{
      track_id: track,
      note_id: "n3",
      after_id: "n2",
      old_span: {960, 1440},
      new_span: {1440, 1920}
    },
    ws,
    cfg
  )

{:ok, ws} = Workspace.apply_batch(ws, track, ws.edit_version, ops, ch)

IO.puts("\n=== Act 1: drag n3 [960, 1440] -> [1440, 1920] ===")
IO.puts("warp pieces for the batch:")

wp = WarpProvider.tick(Track.spans(ws.tracks[track]), ws.tracks[track].patches)
{:ok, w} = wp.(:tick, {ws.tracks[track].space.version, ops})
show_pieces.(w)

IO.puts("sample points:")
IO.puts("  at 700  -> #{inspect(Warp.at!(w, 700))}   (before n3: identity)")
IO.puts("  at 1000 -> #{inspect(Warp.at!(w, 1000))}  (inside n3: shifted +480)")
IO.puts("  at 1500 -> #{inspect(Warp.at!(w, 1500))}  (vacated region: hole)")
IO.puts("  at 2100 -> #{inspect(Warp.at!(w, 2100))}  (past everything: identity)")

transport_and_report.(ws, "transport after act 1 (curve follows n3)")

# ---- 4. Act 2: shrink n2 to a third of its length ----
{:ok, ops, ch} =
  Operation.lower(
    %Coconut.Edit.Operations.DragNote{
      track_id: track,
      note_id: "n2",
      after_id: "n1",
      old_span: {480, 960},
      new_span: {480, 640}
    },
    ws,
    cfg
  )

{:ok, ws} = Workspace.apply_batch(ws, track, ws.edit_version, ops, ch)

IO.puts("\n=== Act 2: shrink n2 [480, 960] -> [480, 640] (slope 1/3) ===")
IO.puts("warp pieces for the batch:")

wp = WarpProvider.tick(Track.spans(ws.tracks[track]), ws.tracks[track].patches)
{:ok, w} = wp.(:tick, {ws.tracks[track].space.version, ops})
show_pieces.(w)

IO.puts("sample points (exact rationals, no float dust):")
IO.puts("  at 500 -> #{inspect(Warp.at!(w, 500))}")
IO.puts("  at 700 -> #{inspect(Warp.at!(w, 700))}")

transport_and_report.(ws, "transport after act 2 (vibrato compresses 1/3)")

# ---- 5. Check round while everything is alive ----
channels =
  [:energy, :vibrato, :curve, :space]
  |> Map.new(&{&1, Coconut.Examples.WarpChannel})

IO.puts("\n=== Resolve.run_check (all alive) ===")

case Resolve.run_check(ws, channels) do
  {:ok, %{interventions: interventions, survivors: survivors}} ->
    IO.puts("resolved #{length(survivors)} patches, interventions:")
    IO.inspect(interventions)

  {:ok, %{passed: false, entries: entries}} ->
    IO.puts("unexpected veto:")
    Enum.each(entries, fn e -> IO.inspect({e.kind, e.channel, e[:reason]}) end)
end

# ---- 6. Act 3: delete n3 — the curve patch loses its ground ----
{:ok, ops, ch} =
  Operation.lower(%Coconut.Edit.Operations.DeleteNote{track_id: track, note_id: "n3"}, ws, cfg)

{:ok, ws} = Workspace.apply_batch(ws, track, ws.edit_version, ops, ch)

IO.puts("\n=== Act 3: delete n3 (now at [1440, 1920]) ===")
IO.puts("warp pieces for the batch:")

wp = WarpProvider.tick(Track.spans(ws.tracks[track]), ws.tracks[track].patches)
{:ok, w} = wp.(:tick, {ws.tracks[track].space.version, ops})
show_pieces.(w)

transport_and_report.(ws, "transport after act 3 (live set already folded by apply_batch)")

IO.puts("surfaced at write time (track.dead_patches):")

Enum.each(ws.tracks[track].dead_patches, fn {cp, reason} ->
  IO.puts("  DIES      #{cp.channel}: #{inspect(reason)}")
end)

# ---- 7. Check round: the dead patch is out of the live set ----
IO.puts("\n=== Resolve.run_check (curve already in the graveyard) ===")

case Resolve.run_check(ws, channels) do
  {:ok, %{interventions: interventions, survivors: survivors}} ->
    IO.puts("resolved #{length(survivors)} patches — no veto, the dead one is out:")
    IO.inspect(interventions)

  {:ok, %{passed: false, entries: entries}} ->
    IO.puts("unexpected veto:")
    Enum.each(entries, fn e -> IO.inspect({e.kind, e.channel, e[:reason]}) end)
end

IO.puts("\nDone.")
