# Example: basic edit pipeline
#
# Creates a workspace with a note track and tempo track, inserts notes,
# attaches patches, edits, and transports.

alias Coconut.{Operate, Patch, WarpProvider, Workspace, MockEngine}
alias Coconut.Util.ID

cfg = %Operate.Config{}
track = :vocal

# ---- 1. Bootstrap workspace ----
{:ok, ws} =
  Workspace.new(%{
    id: ID.generate_id("WSpc_"),
    edit_version: 0,
    tempo_space: %Tamale.Space{},
    tracks: %{track => %Tamale.Space{}},
    side: %Workspace.Side{}
  })

# ---- 2. Insert tempo event ----
{:ok, ops, ch} =
  Operate.lower({:insert_note, :tempo, "t0", :head, {0, 9600}, %{bpm: 120_000}}, ws, cfg)
{:ok, ws} = Workspace.apply_batch(ws, :tempo, 0, ops, ch)

# ---- 3. Insert notes ----
notes = [
  {"n1", :head, {0, 480}, %{pitch: 60, lyric: "\u3089"}},
  {"n2", "n1", {480, 960}, %{pitch: 62, lyric: "\u308a"}},
  {"n3", "n2", {960, 1440}, %{pitch: 64, lyric: "\u308b"}},
]

ws =
  Enum.reduce(notes, {ws, 1}, fn {id, after_id, span, attrs}, {ws, ver} ->
    {:ok, ops, ch} = Operate.lower({:insert_note, track, id, after_id, span, attrs}, ws, cfg)
    {:ok, ws} = Workspace.apply_batch(ws, track, ver, ops, ch)
    {ws, ver + 1}
  end)
  |> elem(0)

IO.puts("=== After insert ===")
IO.inspect(ws.tracks[track].ids, label: "order")
IO.inspect(MockEngine.render(ws), label: "render")

# ---- 4. Attach patches ----
{:ok, cp1} = Patch.new(%{
  track_id: track,
  anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: ws.tracks[track].version},
  patch: %Tamale.Patch{base_digest: "deadbeef", payload: %{lyric: "\u3089\u3093"}}
})
{:ok, cp2} = Patch.new(%{
  track_id: track,
  anchor: %Tamale.Anchor.Metric{coord: :tick, from: 600, to: 800, at_version: ws.tracks[track].version},
  patch: %Tamale.Patch{base_digest: "cafebabe", payload: %{energy: 0.8}}
})
{:ok, cp3} = Patch.new(%{
  track_id: track,
  anchor: %Tamale.Anchor.Relative{ref: "n3", from_offset: 50, to_offset: 100, at_version: ws.tracks[track].version},
  patch: %Tamale.Patch{base_digest: "ba5eba11", payload: %{breathiness: 0.3}}
})

ws = %{ws | side: %{ws.side | patches: [cp1, cp2, cp3]}}

# ---- 5. Edit: drag n1 (Move + Retime) ----
{:ok, ops, ch} =
  Operate.lower({:drag_note, track, "n1", :head, {0, 480}, {100, 580}}, ws, cfg)
{:ok, ws} = Workspace.apply_batch(ws, track, ws.edit_version, ops, ch)

IO.puts("\n=== After drag n1 (0..480 -> 100..580) ===")
IO.inspect(ws.tracks[track].ids, label: "order")
IO.inspect(MockEngine.render(ws), label: "render")

# ---- 6. Transport patches ----
wp = WarpProvider.tick(Workspace.track_spans(ws, track))
{:ok, survivors, dead} = Workspace.transport_patches(ws, track, wp)

IO.puts("\n=== Transport results ===")
IO.puts("Survivors: #{length(survivors)}")
Enum.each(survivors, fn cp ->
  case cp.anchor do
    %Tamale.Anchor.Ordinal{refs: refs} -> IO.puts("  Ordinal refs=#{inspect(refs)}")
    %Tamale.Anchor.Metric{from: f, to: t} -> IO.puts("  Metric from=#{inspect(f)} to=#{inspect(t)}")
    %Tamale.Anchor.Relative{ref: r} -> IO.puts("  Relative ref=#{inspect(r)}")
  end
end)
IO.puts("Dead: #{length(dead)}")
Enum.each(dead, fn {cp, reason} ->
  IO.puts("  #{inspect(cp.anchor.__struct__)} reason=#{inspect(reason)}")
end)

# ---- 7. Project relative to Metric ----
survivor_rel = Enum.find(survivors, fn cp -> match?(%Tamale.Anchor.Relative{}, cp.anchor) end)
if survivor_rel do
  track_vers = Workspace.track_spans(ws, track)
  latest = Enum.max(Map.keys(track_vers))
  span_fn = fn id -> Map.get(track_vers[latest], id) end
  {:ok, metric} = Tamale.Anchor.project(survivor_rel.anchor, :tick, span_fn)
  IO.puts("\n=== Relative -> Metric projection ===")
  IO.inspect(metric, label: "projected")
end

# ---- 8. TempoMap: tick to seconds ----
{:ok, tm} = Workspace.tempo_map(ws)
n1_span = ws.side.spans_by_version[track]
          |> Map.get(ws.tracks[track].version, %{})
          |> Map.get("n1")
IO.puts("\n=== TempoMap ===")
if n1_span do
  sec_start = Coconut.Score.TempoMap.tick_to_sec(tm, elem(n1_span, 0), 480)
  IO.puts("n1 at tick #{elem(n1_span, 0)} = #{Float.round(sec_start, 4)} sec")
end

IO.puts("\nDone.")
