defmodule Coconut.FacadeTest do
  use ExUnit.Case, async: true

  alias Coconut.Edit.{Command, Track}
  alias Coconut.Edit.Operations.{EditNote, InsertNote}
  alias Coconut.Engines.Mock
  alias Coconut.Project
  alias Coconut.Render.Channels.Lyric
  alias Coconut.Scenario

  @track "vocal"

  defp session(opts \\ []) do
    defaults = [channels: %{lyric: Lyric}, engine: Mock]
    {:ok, session} = Coconut.new(Scenario.base_workspace(), Keyword.merge(defaults, opts))
    session
  end

  defp insert(session, id \\ "n1", after_id \\ :head) do
    Coconut.edit(session, %InsertNote{
      track_id: @track,
      note_id: id,
      after_id: after_id,
      span: {0, 480},
      attrs: %{lyric: "la", pitch: 60}
    })
  end

  test "edit, undo, and redo expose one host-safe write path" do
    session = session()
    assert Coconut.pin(session) == 0

    assert {:ok, session} = insert(session)
    assert Coconut.pin(session) == 1
    assert %{workspace: current, pin: 1} = Coconut.current(session)
    assert current == Coconut.workspace(session)
    assert [{"n1", _note, {0, 480}}] = Track.view(Coconut.workspace(session).tracks[@track])

    assert {:ok, session} = Coconut.undo(session)
    assert Track.view(Coconut.workspace(session).tracks[@track]) == []

    assert {:ok, session} = Coconut.redo(session)
    assert [{"n1", _note, {0, 480}}] = Track.view(Coconut.workspace(session).tracks[@track])
  end

  test "a project session exports current workspace without persisting session state" do
    workspace = Scenario.base_workspace()

    {:ok, project} =
      Project.new(%{
        id: "project",
        workspace: workspace,
        voicebank: %{name: "voice", engine: :mock, digest: "sha256"},
        metadata: %{title: "demo"}
      })

    assert {:ok, session} = Coconut.new(project, channels: %{lyric: Lyric}, engine: Mock)
    assert {:ok, session} = insert(session)
    assert {:ok, exported} = Coconut.project(session)

    assert exported.id == project.id
    assert exported.voicebank == project.voicebank
    assert exported.metadata == project.metadata
    assert exported.workspace == Coconut.workspace(session)
    refute Map.has_key?(Map.from_struct(exported), :history)
  end

  test "mount captures projection and render performs resolve, check, and render" do
    assert {:ok, session} = insert(session())

    assert {:ok, session, patch} =
             Coconut.mount(session, @track, "n1", :lyric, %{value: "lai"})

    assert String.starts_with?(patch.id, "Patch_")

    assert {:ok, %{interventions: interventions, survivors: [survivor]}} =
             Coconut.resolve(session)

    assert survivor.id == patch.id
    assert interventions == %{{:port, :synth, :lyric} => %{input: %{value: "lai"}}}

    assert {:ok, checked_session, artifact} = Coconut.render(session)
    assert artifact.edit_version == Coconut.workspace(session).edit_version
    assert artifact.overrides == interventions
    assert {:ok, nil} = Coconut.checked(checked_session)
  end

  test "writes invalidate a checked round" do
    assert {:ok, session} = insert(session())
    assert {:ok, session} = Coconut.check(session)
    assert {:ok, nil} = Coconut.checked(session)

    assert {:ok, command} = Command.add_track(%{id: "harmony", module: Track.Vocal})
    assert {:ok, session} = Coconut.run(session, command)
    assert {:error, :not_checked} = Coconut.checked(session)
  end

  test "render inputs can be reconfigured without rebuilding edit history" do
    assert {:ok, session} = insert(session())
    pin = Coconut.pin(session)

    assert {:ok, session} =
             Coconut.configure(session,
               interventions: %{{:port, :base, :lyrics} => %{input: :base}},
               globals: %{depth: 0.5}
             )

    assert Coconut.pin(session) == pin
    assert {:ok, _session, artifact} = Coconut.render(session)
    assert artifact.globals == %{depth: 0.5}
    assert artifact.overrides[{:port, :base, :lyrics}] == %{input: :base}
  end

  test "resolve conflicts are discarded through an undoable command" do
    assert {:ok, session} = insert(session())
    assert {:ok, session, patch} = Coconut.mount(session, @track, "n1", :lyric, :override)

    assert {:ok, session} =
             Coconut.edit(session, %EditNote{
               track_id: @track,
               note_id: "n1",
               changes: %{lyric: "new lyric"}
             })

    assert {:error, {:resolve_vetoed, [entry]}} = Coconut.resolve(session)
    assert entry.patch.id == patch.id

    assert {:ok, session} = Coconut.discard_conflicts(session, [entry])
    assert {:ok, %{interventions: %{}, survivors: []}} = Coconut.resolve(session)

    assert {[{dead, :base_changed}], session} = Coconut.take_dead_patches(session)
    assert dead.id == patch.id

    assert {:ok, session} = Coconut.undo(session)
    assert [{restored, :base_changed}] = Coconut.workspace(session).tracks[@track].dead_patches
    assert restored.id == patch.id

    assert {:ok, session} = Coconut.undo(session)
    assert [%{id: restored_id}] = Coconut.workspace(session).tracks[@track].patches
    assert restored_id == patch.id
  end

  test "active patches can be explicitly superseded without touching track internals" do
    assert {:ok, session} = insert(session())
    assert {:ok, session, patch} = Coconut.mount(session, @track, "n1", :lyric, :old)

    assert {:ok, session} = Coconut.discard_patches(session, patch, :superseded)
    assert Coconut.workspace(session).tracks[@track].patches == []
    assert [{discarded, :superseded}] = Coconut.workspace(session).tracks[@track].dead_patches
    assert discarded.id == patch.id

    assert {:ok, session} = Coconut.undo(session)
    assert [%{id: restored_id}] = Coconut.workspace(session).tracks[@track].patches
    assert restored_id == patch.id
  end

  test "facade validates configuration and reports missing dependencies" do
    workspace = Scenario.base_workspace()

    assert {:error, {:invalid_channel, {:bad, String}}} =
             Coconut.new(workspace, channels: %{bad: String})

    assert {:error, {:invalid_engine, String}} = Coconut.new(workspace, engine: String)

    assert {:ok, session} = Coconut.new(workspace)
    assert {:error, :missing_engine} = Coconut.check(session)

    assert {:error, {:unknown_channel, :lyric}} =
             Coconut.mount(session, @track, "n1", :lyric, :payload)

    assert {:error, :workspace_session} = Coconut.project(session)
    assert {:error, {:invalid_option, :globals, :bad}} = Coconut.request(session, globals: :bad)
  end
end
