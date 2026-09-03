# Example: basic edit pipeline
#
# Creates a workspace with a note track and tempo track, inserts notes,
# mounts patches, edits, transports, and runs a Resolve + Engine round.

alias Coconut.Edit.{Patch, Track, WarpProvider, Workspace}
alias Coconut.Render.{Engine, Resolve}
alias Coconut.Edit.{Operation}
alias Coconut.Render.Engine.Request
alias Coconut.Engines.Mock
alias Coconut.Util.ID

defmodule Coconut.Examples.BasicChannel do
  @behaviour Coconut.Render.Channel

  alias Coconut.Edit.{Patch, Track}

  @impl true
  def projection(ws, %Patch{track_id: track_id} = patch) do
    case patch.anchor do
      %Tamale.Anchor.Ordinal{refs: [id | _]} ->
        fetch_element(ws, track_id, id)

      %Tamale.Anchor.Relative{ref: id} ->
        fetch_element(ws, track_id, id)

      %Tamale.Anchor.Metric{from: from, to: to} ->
        from_tick = to_tick(from)
        to_tick = to_tick(to)

        overlapping =
          for {id, {start_tick, end_tick}} <- Track.latest_spans(ws.tracks[track_id]),
              start_tick < to_tick and end_tick > from_tick,
              into: %{} do
            {id, canonicalize(Map.get(ws.tracks[track_id].elements_by_id, id))}
          end

        {:ok, overlapping}
    end
  end

  @impl true
  def target(%Patch{channel: channel}), do: {:port, :synth, channel}

  defp fetch_element(ws, track_id, id) do
    with {:ok, element} <- Map.fetch(ws.tracks[track_id].elements_by_id, id) do
      {:ok, canonicalize(element)}
    end
  end

  defp canonicalize(%Coconut.Score.Note{} = note), do: Coconut.Score.Note.to_canonical(note)
  defp canonicalize(other), do: other
  defp to_tick({numerator, denominator}), do: div(numerator, denominator)
  defp to_tick(tick) when is_integer(tick), do: tick
end

cfg = %Operation.Config{}
track = "vocal"

# ---- 1. Bootstrap workspace ----
{:ok, tempo_track} = Track.new(%{id: "global:tempo", module: Track.Tempo})
{:ok, vocal_track} = Track.new(%{id: track, module: Track.Vocal})

{:ok, ws} =
  Workspace.new(%{
    id: ID.generate_id("WSpc_"),
    edit_version: 0,
    tracks: %{track => vocal_track},
    globals: %{"global:tempo" => tempo_track}
  })

# ---- 2. Insert tempo event ----
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

# ---- 3. Insert notes ----
notes = [
  {"n1", :head, {0, 480}, %{pitch: 60, lyric: "ら"}},
  {"n2", "n1", {480, 960}, %{pitch: 62, lyric: "り"}},
  {"n3", "n2", {960, 1440}, %{pitch: 64, lyric: "る"}}
]

ws =
  Enum.reduce(notes, {ws, 1}, fn {id, after_id, span, attrs}, {ws, ver} ->
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

    {:ok, ws} = Workspace.apply_batch(ws, track, ver, ops, ch)
    {ws, ver + 1}
  end)
  |> elem(0)

IO.puts("=== After insert ===")
IO.inspect(ws.tracks[track].space.ids, label: "order")
{:ok, request} = Request.for_workspace(ws)
{:ok, art} = Engine.run_render(Mock, request, nil)
IO.inspect(art.payload.notes, label: "render")

# ---- 4. Mount patches (mount = capture base via projection) ----

ver = ws.tracks[track].space.version

mount = fn anchor, channel, payload ->
  probe = %Patch{track_id: track, anchor: anchor, channel: channel}
  {:ok, base} = Coconut.Examples.BasicChannel.projection(ws, probe)
  {:ok, tp} = Tamale.Patch.new(base, payload)
  {:ok, cp} = Patch.new(%{track_id: track, anchor: anchor, channel: channel, patch: tp})
  cp
end

cp1 = mount.(%Tamale.Anchor.Ordinal{refs: ["n1"], at_version: ver}, :lyric, %{lyric: "らん"})

cp2 =
  mount.(%Tamale.Anchor.Metric{coord: :tick, from: 600, to: 800, at_version: ver}, :energy, %{
    energy: 80
  })

cp3 =
  mount.(
    %Tamale.Anchor.Relative{ref: "n3", from_offset: 50, to_offset: 100, at_version: ver},
    :breath,
    %{breathiness: 30}
  )

{:ok, ws, _minted} = Workspace.attach_patches(ws, [cp1, cp2, cp3])

# ---- 5. Edit: drag n1 (Move + Retime) ----
{:ok, ops, ch} =
  Operation.lower(
    %Coconut.Edit.Operations.DragNote{
      track_id: track,
      note_id: "n1",
      after_id: :head,
      old_span: {0, 480},
      new_span: {100, 480}
    },
    ws,
    cfg
  )

{:ok, ws} = Workspace.apply_batch(ws, track, ws.edit_version, ops, ch)

IO.puts("\n=== After drag n1 (0..480 -> 100..480) ===")
IO.inspect(ws.tracks[track].space.ids, label: "order")
{:ok, request} = Request.for_workspace(ws)
{:ok, art} = Engine.run_render(Mock, request, nil)
IO.inspect(art.payload.notes, label: "render")

# ---- 6. Transport patches ----
wp = WarpProvider.tick(Track.spans(ws.tracks[track]))
{:ok, survivors, dead} = Track.transport_patches(ws.tracks[track], wp)

IO.puts("\n=== Transport results ===")
IO.puts("Survivors: #{length(survivors)}")

Enum.each(survivors, fn cp ->
  case cp.anchor do
    %Tamale.Anchor.Ordinal{refs: refs} ->
      IO.puts("  Ordinal refs=#{inspect(refs)}")

    %Tamale.Anchor.Metric{from: f, to: t} ->
      IO.puts("  Metric from=#{inspect(f)} to=#{inspect(t)}")

    %Tamale.Anchor.Relative{ref: r} ->
      IO.puts("  Relative ref=#{inspect(r)}")
  end
end)

IO.puts("Dead: #{length(dead)}")

Enum.each(dead, fn {cp, reason} ->
  IO.puts("  #{inspect(cp.anchor.__struct__)} reason=#{inspect(reason)}")
end)

# ---- 7. Project relative to Metric ----
survivor_rel = Enum.find(survivors, fn cp -> match?(%Tamale.Anchor.Relative{}, cp.anchor) end)

if survivor_rel do
  span_fn = &Track.latest_span(ws.tracks[track], &1)
  {:ok, metric} = Tamale.Anchor.project(survivor_rel.anchor, :tick, span_fn)
  IO.puts("\n=== Relative -> Metric projection ===")
  IO.inspect(metric, label: "projected")
end

# ---- 8. TempoMap: tick to seconds ----
{:ok, tm} = Workspace.tempo_map(ws)
n1_span = Track.latest_span(ws.tracks[track], "n1")
IO.puts("\n=== TempoMap ===")

if n1_span do
  sec_start = Coconut.Score.TempoMap.tick_to_sec(tm, elem(n1_span, 0))
  IO.puts("n1 at tick #{elem(n1_span, 0)} = #{Float.round(sec_start, 4)} sec")
end

# ---- 9. Resolve + Engine round ----
channels =
  [:lyric, :energy, :breath]
  |> Map.new(&{&1, Coconut.Examples.BasicChannel})

IO.puts("\n=== Resolve.run_check ===")

case Resolve.run_check(ws, channels) do
  {:ok, %{interventions: interventions, survivors: resolved}} ->
    IO.puts("resolved #{length(resolved)} patches")
    IO.inspect(interventions, label: "interventions")

    {:ok, request} = Request.for_workspace(ws, interventions: interventions)
    {:ok, %{checked: checked}} = Engine.run_check(Mock, request)
    {:ok, artifact} = Engine.run_render(Mock, request, checked)
    IO.inspect(artifact.overrides, label: "engine overrides")

  {:ok, %{passed: false, entries: entries}} ->
    IO.puts("check failed:")
    Enum.each(entries, fn e -> IO.inspect({e.kind, e.channel, e[:reason]}, label: "entry") end)
end

IO.puts("\nDone.")
