# Spike: multi-track edit pipeline
# Two sub-tracks share overlapping tick spans without conflict.

alias Coconut.{Operate, Patch, WarpProvider, Workspace, Engine.MockEngine}
alias Coconut.Util.ID

cfg = %Operate.Config{}
track_a = :vocal_a
track_b = :vocal_b

{:ok, ws} =
  Workspace.new(%{
    id: ID.generate_id("WSpc_"),
    edit_version: 0,
    tempo_space: %Tamale.Space{},
    tracks: %{track_a => %Tamale.Space{}, track_b => %Tamale.Space{}},
    side: %Workspace.Side{}
  })

# ---- Tempo ----
{:ok, ops, ch} =
  Operate.lower({:insert_note, :tempo, "t0", :head, {0, 9600}, %{bpm: 120_000}}, ws, cfg)
{:ok, ws} = Workspace.apply_batch(ws, :tempo, 0, ops, ch)

# ---- Track A: melody ----
{:ok, ops_a, ch_a} = Operate.lower({:insert_note, track_a, "a1", :head, {0, 480}, %{pitch: 60}}, ws, cfg)
{:ok, ws} = Workspace.apply_batch(ws, track_a, 1, ops_a, ch_a)
{:ok, ops_a2, ch_a2} = Operate.lower({:insert_note, track_a, "a2", "a1", {480, 960}, %{pitch: 64}}, ws, cfg)
{:ok, ws} = Workspace.apply_batch(ws, track_a, 2, ops_a2, ch_a2)

# ---- Track B: harmony, overlaps with A ----
{:ok, ops_b, ch_b} = Operate.lower({:insert_note, track_b, "b1", :head, {240, 720}, %{pitch: 55}}, ws, cfg)
{:ok, ws} = Workspace.apply_batch(ws, track_b, 3, ops_b, ch_b)

IO.puts("=== After insert (both tracks) ===")
IO.inspect(ws.tracks[track_a].ids, label: "#{track_a} order")
IO.inspect(ws.tracks[track_b].ids, label: "#{track_b} order")
IO.inspect(MockEngine.render(ws), label: "render (flat)")

# ---- Attach patches to A ----
{:ok, cp_a} = Patch.new(%{
  track_id: track_a,
  anchor: %Tamale.Anchor.Ordinal{refs: ["a1"], at_version: ws.tracks[track_a].version},
  patch: %Tamale.Patch{base_digest: "aaa", payload: %{}}
})
ws = Workspace.attach_patch(ws, cp_a)

# ---- Drag a1 (overlaps b1) ----
{:ok, ops, ch} =
  Operate.lower({:drag_note, track_a, "a1", :head, {0, 480}, {0, 600}}, ws, cfg)
{:ok, ws} = Workspace.apply_batch(ws, track_a, ws.edit_version, ops, ch)

IO.puts("\n=== After drag a1 to {0,600} ===")
IO.inspect(MockEngine.render(ws), label: "render")
# a1 {0,600} overlaps b1 {240,720} at {240,600} -- fine, different tracks

# ---- Transport (track A only) ----
wp = WarpProvider.tick(Workspace.track_spans(ws, track_a))
{:ok, survivors, dead} = Workspace.transport_patches(ws, track_a, wp)
IO.puts("\nTransport track A: survivors=#{length(survivors)} dead=#{length(dead)}")

# ---- Transport (track B -- no patches, but verify Space isolation) ----
IO.inspect(ws.tracks[track_b].ids, label: "#{track_b} unchanged")
IO.inspect(ws.tracks[track_b].version, label: "#{track_b} version")

IO.puts("\nDone.")
