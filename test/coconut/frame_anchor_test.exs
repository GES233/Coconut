defmodule Coconut.Edit.FrameAnchorTest do
  @moduledoc """
  帧域 Metric 锚在 tick 轨上的端到端：写时 transport 的 T 对组合、
  tempo echo transport、version_clock 记录与裁剪（设计文档 §5 第 4 条）。

  数字基准：tpqn 480、frame_rate 100。120 bpm → 5/48 帧/tick
  （480 ticks = 50 帧）；60 bpm → 5/24 帧/tick。
  """
  use ExUnit.Case, async: true

  alias Coconut.Edit.{Operation, Patch, Track, Workspace}

  alias Coconut.Edit.Operations.{
    EditNote,
    InsertNote,
    TrimNote
  }

  alias Coconut.Util.ID

  @track "vocal"
  @tempo "global:tempo"

  setup do
    {:ok, vocal} = Track.new(%{id: @track, module: Track.Vocal})

    {:ok, ws} =
      Workspace.new(%{
        id: ID.generate_id("WSpc_"),
        edit_version: 0,
        tracks: %{@track => vocal},
        frame_rate: 100
      })

    {:ok, ws: ws}
  end

  defp apply_gesture(ws, req) do
    :ok = Operation.validate(req, ws)
    {:ok, ops, changes} = Operation.lower(req, ws, %Operation.Config{})
    {:ok, ws} = Workspace.apply_batch(ws, req.track_id, ws.edit_version, ops, changes)
    ws
  end

  defp insert_tempo(ws, id, span, bpm) do
    after_id =
      case tempo_track(ws).space.ids do
        [] -> :head
        ids -> List.last(ids)
      end

    apply_gesture(ws, %InsertNote{
      track_id: @tempo,
      note_id: id,
      after_id: after_id,
      span: span,
      attrs: %{bpm: bpm}
    })
  end

  defp insert_note(ws, id, span) do
    apply_gesture(ws, %InsertNote{
      track_id: @track,
      note_id: id,
      after_id: List.last(track(ws).space.ids) || :head,
      span: span,
      attrs: %{pitch: 60}
    })
  end

  defp track(ws), do: elem(Workspace.fetch_track(ws, @track), 1)
  defp tempo_track(ws), do: elem(Workspace.fetch_track(ws, @tempo), 1)

  defp metric_patch(track_id, coord, from, to, at_version) do
    {:ok, patch} =
      Patch.new(%{
        track_id: track_id,
        channel: :energy,
        anchor: %Tamale.Anchor.Metric{coord: coord, from: from, to: to, at_version: at_version},
        patch: %Tamale.Patch{base_digest: "d", payload: %{}}
      })

    patch
  end

  # 标准乐谱：t0 [0,1920)@120；n1 [0,480)、n2 [480,960)
  defp build_score(ws) do
    ws
    |> insert_tempo("t0", {0, 1920}, 120)
    |> insert_note("n1", {0, 480})
    |> insert_note("n2", {480, 960})
  end

  describe "mount guard" do
    test "a frame Metric anchor on a tick track requires frame_rate" do
      {:ok, vocal} = Track.new(%{id: @track, module: Track.Vocal})

      {:ok, ws} =
        Workspace.new(%{
          id: ID.generate_id("WSpc_"),
          edit_version: 0,
          tracks: %{@track => vocal}
        })

      patch = metric_patch(@track, :frame, 0, 50, 0)
      assert {:error, :missing_frame_rate} = Workspace.attach_patch(ws, patch)
    end

    test "a frame Metric anchor mounts once frame_rate is declared", %{ws: ws} do
      patch = metric_patch(@track, :frame, 0, 50, 0)
      assert {:ok, _ws, _minted} = Workspace.attach_patch(ws, patch)
    end
  end

  describe "write-time transport (T pair composition)" do
    test "a note retime moves the frame anchor through the tempo staircase", %{ws: ws} do
      ws = build_score(ws)

      {:ok, ws, _} =
        Workspace.attach_patch(ws, metric_patch(@track, :frame, 0, 50, 2))

      ws =
        apply_gesture(ws, %TrimNote{
          track_id: @track,
          note_id: "n1",
          old_span: {0, 480},
          new_span: {0, 240}
        })

      # 50 帧 = 480 ticks → 缩到 240 ticks → 25 帧，精确有理数
      assert [%{anchor: %{coord: :frame, from: {0, 1}, to: {25, 1}}}] = track(ws).patches
    end

    test "a mixed tempo+vocal gesture uses the entry's {T_old, T_new} pair", %{ws: ws} do
      # n3 [1920,2400)：60bpm 区域（t1 插入后）恰好覆盖它
      ws = insert_note(build_score(ws), "n3", {1920, 2400})

      {:ok, ws, _} = Workspace.attach_patch(ws, metric_patch(@track, :frame, 0, 50, 3))
      {:ok, ws, _} = Workspace.attach_patch(ws, metric_patch(@track, :frame, 200, 250, 3))

      ins = %InsertNote{
        track_id: @tempo,
        note_id: "t1",
        after_id: "t0",
        span: {1920, 3840},
        attrs: %{bpm: 60}
      }

      trim = %TrimNote{
        track_id: @track,
        note_id: "n3",
        old_span: {1920, 2400},
        new_span: {1920, 2160}
      }

      {:ok, ops1, ch1} = Operation.lower(ins, ws, %Operation.Config{})
      {:ok, ops2, ch2} = Operation.lower(trim, ws, %Operation.Config{})

      {:ok, ws} =
        Workspace.apply_batches(ws, ws.edit_version, [
          {@tempo, ops1, ch1},
          {@track, ops2, ch2}
        ])

      # 本手势没动 n1/n2，p1 [0,50] 帧不变；p3 [200,250] 帧覆盖 n3：
      # span 减半（2400→2160 ticks）恰好被 tempo 减半（120→60）抵消，
      # 帧坐标不变——若错用单一当前 T（而非本 entry 的 {T_old, T_new}
      # 对），p3 会被错算成 [200, 225]
      assert [
               %{anchor: %{from: {0, 1}, to: {50, 1}}},
               %{anchor: %{from: {200, 1}, to: {250, 1}}}
             ] = track(ws).patches
    end
  end

  describe "tempo echo transport (pure tempo edit)" do
    test "frame anchors follow a tempo insert; tick and ordinal anchors do not", %{ws: ws} do
      ws = build_score(ws)

      {:ok, ws, _} = Workspace.attach_patch(ws, metric_patch(@track, :frame, 200, 250, 2))
      {:ok, ws, _} = Workspace.attach_patch(ws, metric_patch(@track, :tick, 0, 480, 2))

      {:ok, ordinal} =
        Patch.new(%{
          track_id: @track,
          channel: :lyric,
          anchor: %Tamale.Anchor.Ordinal{refs: ["n1"], at_version: 2},
          patch: %Tamale.Patch{base_digest: "d", payload: %{}}
        })

      {:ok, ws, _} = Workspace.attach_patch(ws, ordinal)

      # 纯 tempo 手势：t1 [1920,3840)@60 —— vocal 轨 log 无新条目
      ws = insert_tempo(ws, "t1", {1920, 3840}, 60)

      # 帧锚 [200,250]：T_old⁻¹ → ticks [1920,2400] → T_new（60bpm 段
      # 5/24 帧/tick）→ [200, 300]；tick 锚与 Ordinal 原样
      assert [
               %{anchor: %{coord: :frame, from: {200, 1}, to: {300, 1}}},
               %{anchor: %{coord: :tick, from: 0, to: 480}},
               %{anchor: %Tamale.Anchor.Ordinal{refs: ["n1"]}}
             ] = track(ws).patches

      assert track(ws).dead_patches == []
    end

    test "a bpm value edit (content, unversioned) leaves the clock and anchors as-is",
         %{ws: ws} do
      ws = insert_note(insert_tempo(ws, "t0", {0, 1920}, 120), "n1", {0, 480})

      {:ok, ws, _} = Workspace.attach_patch(ws, metric_patch(@track, :frame, 0, 50, 1))

      ws =
        apply_gesture(ws, %EditNote{
          track_id: @tempo,
          note_id: "t0",
          changes: %{bpm: 240}
        })

      # bpm 改值不落 op：tempo 轨 clock 不被覆写，两端 tempo 一致 → echo 恒等
      # （锚坐标经恒等 warp 走一趟，被规范化为有理数 Coord 形状）
      assert tempo_track(ws).version_clock == %{1 => 1}
      assert tempo_track(ws).elements_by_id["t0"] == %{bpm: 240_000}

      assert [%{anchor: %{from: {0, 1}, to: {50, 1}}}] = track(ws).patches
      assert track(ws).dead_patches == []
    end

    test "the first tempo event kills pre-existing frame anchors (undatable T_old)",
         %{ws: ws} do
      # 无 tempo 事件时挂帧锚（frame_rate 已声明），首个 tempo 事件到来时
      # 无法构造 T_old → 可见判死，而非静默错位
      ws = insert_note(ws, "n1", {0, 480})

      {:ok, ws, _} = Workspace.attach_patch(ws, metric_patch(@track, :frame, 0, 50, 1))

      ws = insert_tempo(ws, "t0", {0, 1920}, 120)

      assert track(ws).patches == []

      assert [{_patch, {:warp_construction_failed, :missing_tempo_events}}] =
               track(ws).dead_patches
    end
  end

  describe "version clock" do
    test "batches record space-version → edit_version; truncate keeps a baseline",
         %{ws: ws} do
      ws = build_score(ws)

      assert track(ws).version_clock == %{1 => 2, 2 => 3}
      assert tempo_track(ws).version_clock == %{1 => 1}

      {:ok, ws} = Workspace.truncate(ws, @track, 1)

      clock = track(ws).version_clock
      assert clock[1] == 2
      assert clock[2] == 3
    end

    test "tempo_steps_at/2 dates tempo states through the clock", %{ws: ws} do
      ws = build_score(ws)
      ws = insert_tempo(ws, "t1", {1920, 3840}, 60)

      assert Workspace.tempo_steps_at(ws, 0) == nil
      assert Workspace.tempo_steps_at(ws, 1) == [{0, 120_000}]
      assert Workspace.tempo_steps_at(ws, ws.edit_version) == [{0, 120_000}, {1920, 60_000}]
    end
  end
end
