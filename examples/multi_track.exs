# Spike: multi-track edit pipeline
# Two sub-tracks share overlapping tick spans without conflict.

alias Coconut.Edit.{Operation, Patch, Track, WarpProvider, Workspace}
alias Coconut.Render.Engine
alias Coconut.Render.Engine.Request
alias Coconut.Engines.Mock
alias Coconut.Util.ID

cfg = %Operation.Config{}
track_a = "vocal_a"
track_b = "vocal_b"

{:ok, tempo_track} = Track.new(%{id: "global:tempo", module: Track.Tempo})
{:ok, vocal_a} = Track.new(%{id: track_a, module: Track.Vocal})
{:ok, vocal_b} = Track.new(%{id: track_b, module: Track.Vocal})

{:ok, ws} =
  Workspace.new(%{
    id: ID.generate_id("WSpc_"),
    edit_version: 0,
    tracks: %{
      track_a => vocal_a,
      track_b => vocal_b
    },
    globals: %{"global:tempo" => tempo_track}
  })

# ---- Tempo ----
{:ok, ops, ch} =
  Operation.lower(
    %Coconut.Edit.Operations.InsertNote{
      track_id: "global:tempo",
      note_id: "t0",
      after_id: :head,
      span: {0, 9600},
      attrs: %{bpm: 120}
    },
    ws,
    cfg
  )

{:ok, ws} = Workspace.apply_batch(ws, "global:tempo", 0, ops, ch)

# ---- Track A: melody ----
{:ok, ops_a, ch_a} =
  Operation.lower(
    %Coconut.Edit.Operations.InsertNote{
      track_id: track_a,
      note_id: "a1",
      after_id: :head,
      span: {0, 480},
      attrs: %{pitch: 60}
    },
    ws,
    cfg
  )

{:ok, ws} = Workspace.apply_batch(ws, track_a, 1, ops_a, ch_a)

{:ok, ops_a2, ch_a2} =
  Operation.lower(
    %Coconut.Edit.Operations.InsertNote{
      track_id: track_a,
      note_id: "a2",
      after_id: "a1",
      span: {480, 960},
      attrs: %{pitch: 64}
    },
    ws,
    cfg
  )

{:ok, ws} = Workspace.apply_batch(ws, track_a, 2, ops_a2, ch_a2)

# ---- Track B: harmony, overlaps with A ----
{:ok, ops_b, ch_b} =
  Operation.lower(
    %Coconut.Edit.Operations.InsertNote{
      track_id: track_b,
      note_id: "b1",
      after_id: :head,
      span: {240, 720},
      attrs: %{pitch: 55}
    },
    ws,
    cfg
  )

{:ok, ws} = Workspace.apply_batch(ws, track_b, 3, ops_b, ch_b)

IO.puts("=== After insert (both tracks) ===")
IO.inspect(ws.tracks[track_a].space.ids, label: "#{track_a} order")
IO.inspect(ws.tracks[track_b].space.ids, label: "#{track_b} order")
{:ok, request} = Request.for_workspace(ws)
{:ok, art} = Engine.run_render(Mock, request, nil)
IO.inspect(art.payload.notes, label: "render (flat)")

# ---- Attach patches to A ----
{:ok, cp_a} =
  Patch.new(%{
    track_id: track_a,
    anchor: %Tamale.Anchor.Ordinal{refs: ["a1"], at_version: ws.tracks[track_a].space.version},
    patch: %Tamale.Patch{base_digest: "aaa", payload: %{}}
  })

{:ok, ws, _minted} = Workspace.attach_patch(ws, cp_a)

# ---- Drag a1 (overlaps b1) ----
{:ok, ops, ch} =
  Operation.lower(
    %Coconut.Edit.Operations.DragNote{
      track_id: track_a,
      note_id: "a1",
      after_id: :head,
      old_span: {0, 480},
      new_span: {0, 400}
    },
    ws,
    cfg
  )

{:ok, ws} = Workspace.apply_batch(ws, track_a, ws.edit_version, ops, ch)

IO.puts("\n=== After drag a1 to {0,400} ===")
{:ok, request} = Request.for_workspace(ws)
{:ok, art} = Engine.run_render(Mock, request, nil)
IO.inspect(art.payload.notes, label: "render")
# a1 {0,400} overlaps b1 {240,720} at {240,400} -- fine, different tracks

# ---- Transport (track A only) ----
wp = WarpProvider.tick(Track.spans(ws.tracks[track_a]))
{:ok, survivors, dead} = Track.transport_patches(ws.tracks[track_a], wp)
IO.puts("\nTransport track A: survivors=#{length(survivors)} dead=#{length(dead)}")

# ---- Transport (track B -- no patches, but verify Space isolation) ----
IO.inspect(ws.tracks[track_b].space.ids, label: "#{track_b} unchanged")
IO.inspect(ws.tracks[track_b].space.version, label: "#{track_b} version")

IO.puts("\nDone.")
