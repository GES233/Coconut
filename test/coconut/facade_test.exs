defmodule Coconut.FacadeTest do
  use ExUnit.Case, async: true

  alias Coconut.Edit.{Command, Track}
  alias Coconut.Edit.Operations.{EditNote, InsertNote}
  alias Coconut.Engines.Mock
  alias Coconut.Project
  alias Coconut.Render.Channels.Lyric
  alias Coconut.Scenario

  @track "vocal"

  defmodule ProbeChannel do
    @moduledoc false
    @behaviour Coconut.Render.Channel

    alias Coconut.Edit.Patch

    @impl true
    def projection(_ws, _patch), do: {:error, :probe_stage_channel}

    @impl true
    def target(%Patch{anchor: %Tamale.Anchor.Ordinal{refs: [id | _]}}), do: {:port, id, :pin}

    @impl true
    def resolve_stage, do: :probe
  end

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

  test "probe-stage mount requires an explicit base; static channels reject one" do
    session = session(channels: %{lyric: Lyric, pin: ProbeChannel})
    assert {:ok, session} = insert(session)

    assert {:error, {:probe_stage_requires_base, :pin}} =
             Coconut.mount(session, @track, "n1", :pin, [[0, 96]])

    assert {:error, {:static_channel_rejects_base, :lyric, _base}} =
             Coconut.mount(session, @track, "n1", :lyric, :payload, base: ["x"])

    # 显式底料签名：静态 check 不裁决 digest，payload 原样 fold。
    assert {:ok, session, patch} =
             Coconut.mount(session, @track, "n1", :pin, [[0, 96]], base: [["zh", "a"]])

    assert {:ok, %{interventions: interventions, survivors: [survivor]}} =
             Coconut.resolve(session)

    assert survivor.id == patch.id
    assert interventions == %{{:port, "n1", :pin} => %{input: [[0, 96]]}}
  end

  test "repatch_patches discards drifted patches and attaches re-signed ones in one edge" do
    session = session(channels: %{pin: ProbeChannel})
    assert {:ok, session} = insert(session)

    assert {:ok, session, old} =
             Coconut.mount(session, @track, "n1", :pin, [[0, 96]], base: [["zh", "a"]])

    # 底料漂移后重签：新 digest、新 id、payload 保留。
    {:ok, resigned} = Tamale.Patch.new([["zh", "l"], ["zh", "a"]], [[0, 96]])

    {:ok, replacement} =
      Coconut.Edit.Patch.new(%{
        track_id: @track,
        channel: :pin,
        anchor: %Tamale.Anchor.Ordinal{
          refs: ["n1"],
          at_version: Coconut.workspace(session).tracks[@track].space.version
        },
        patch: resigned
      })

    assert {:ok, session} =
             Coconut.run(
               session,
               Command.repatch_patches([{@track, old.id, :base_changed}], [replacement])
             )

    assert [%{id: new_id, patch: ^resigned}] =
             Coconut.workspace(session).tracks[@track].patches

    refute new_id == old.id
    assert [{discarded, :base_changed}] = Coconut.workspace(session).tracks[@track].dead_patches
    assert discarded.id == old.id

    # 一条历史边：undo 一次整批还原（旧 patch 回活，新 patch 消失）。
    assert {:ok, session} = Coconut.undo(session)
    assert [%{id: restored_id}] = Coconut.workspace(session).tracks[@track].patches
    assert restored_id == old.id
    assert Coconut.workspace(session).tracks[@track].dead_patches == []
  end
end
