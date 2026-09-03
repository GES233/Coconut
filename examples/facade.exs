# Run with: mix run examples/facade.exs
#
# A host-facing edit session using only the Coconut facade after bootstrap.
# Importers are still responsible for constructing the initial project and
# domain-specific gesture structs.

alias Coconut.Edit.{Track, Workspace}
alias Coconut.Edit.Operations.{EditNote, InsertNote}
alias Coconut.Engines.Mock
alias Coconut.Project
alias Coconut.Render.Channels.Lyric

track_id = "vocal"

{:ok, vocal} = Track.new(%{id: track_id, module: Track.Vocal, name: "Lead"})

{:ok, workspace} =
  Workspace.new(%{
    id: "workspace",
    tracks: %{track_id => vocal},
    time_sigs: [{1, {4, 4}}]
  })

{:ok, project} =
  Project.new(%{
    id: "facade-example",
    workspace: workspace,
    metadata: %{title: "Facade example"}
  })

{:ok, session} =
  Coconut.new(project,
    channels: %{lyric: Lyric},
    engine: Mock,
    globals: %{depth: 0.5}
  )

insert = fn session, id, after_id, span, lyric, pitch ->
  Coconut.edit(session, %InsertNote{
    track_id: track_id,
    note_id: id,
    after_id: after_id,
    span: span,
    attrs: %{lyric: lyric, pitch: pitch}
  })
end

{:ok, session} = insert.(session, "n1", :head, {0, 480}, "la", 60)
{:ok, session} = insert.(session, "n2", "n1", {480, 960}, "li", 62)

%{pin: pin, workspace: current_workspace} = Coconut.current(session)

IO.inspect(
  %{
    pin: pin,
    edit_version: current_workspace.edit_version,
    note_ids: Enum.map(Track.view(current_workspace.tracks[track_id]), &elem(&1, 0))
  },
  label: "current edit state"
)

{:ok, session, patch} =
  Coconut.mount(session, track_id, "n1", :lyric, %{lyric: "lai"})

{:ok, session, artifact} = Coconut.render(session)
IO.inspect(patch.id, label: "mounted patch")
IO.inspect(artifact.overrides, label: "resolved engine overrides")

# Editing the projected note content invalidates the patch's base digest.
# Resolve reports the conflict; the host explicitly chooses to discard it.
{:ok, session} =
  Coconut.edit(session, %EditNote{
    track_id: track_id,
    note_id: "n1",
    changes: %{lyric: "lu"}
  })

{:error, {:resolve_vetoed, conflicts}} = Coconut.resolve(session)
IO.inspect(Enum.map(conflicts, &{&1.patch.id, &1.reason}), label: "conflicts")

{:ok, session} = Coconut.discard_conflicts(session, conflicts)
{:ok, %{interventions: %{}, survivors: []}} = Coconut.resolve(session)

{dead, session} = Coconut.take_dead_patches(session)

IO.inspect(Enum.map(dead, fn {dead_patch, reason} -> {dead_patch.id, reason} end),
  label: "graveyard"
)

# The graveyard drain and conflict discard are history edges too.
{:ok, session} = Coconut.undo(session)
{:ok, session} = Coconut.undo(session)
[%{id: restored_patch_id}] = Coconut.workspace(session).tracks[track_id].patches
IO.inspect(restored_patch_id, label: "patch restored by undo")

{:ok, latest_project} = Coconut.project(session)
IO.inspect(latest_project.workspace.edit_version, label: "exported edit version")
