defmodule Coconut.Edit.WarpProvider do
  @moduledoc """
  Constructs `Tamale.Warp` segments for Coconut coordinate systems.

  ## v1: non-ripple tick-space

  Piano-roll semantics: global tick coordinates do not shift when notes are
  edited. A Retime moves only the retimed element's own span; a Delete
  removes only its own span; everything else stays put. Per log entry the
  provider folds the batch into one warp:

  | op                                | warp segment                            |
  |-----------------------------------|-----------------------------------------|
  | Retime(id, old, new)              | linear segment `old → new` (op-carried) |
  | Delete(id)                        | hole over the deleted span (span table) |
  | Insert / Move / Split / Merge / … | — (identity)                            |

  Insert's post-insertion shift segment is the ripple extension point
  (design doc §5); v1 non-ripple leaves it out.

  ## Construction

  - A batch with no warp-relevant ops returns `Warp.identity()`.
  - Otherwise the affected intervals plus identity gaps are tiled over
    `[lower, upper]`. The bound comes from every span snapshot, the batch's
    own spans, and every live patch's Metric coordinates — warp pieces are
    finite, so there is no implicit identity tail; the explicit bound keeps
    every live anchor inside the domain.
  - Overlapping affected old-domains (multi-note batches) collapse into one
    hole: a warp cannot map one region two ways.
  - Image monotonicity is enforced in old-domain order: the first piece to
    claim an image region keeps it, later identity pieces are truncated at
    the watermark, later segments drop out and their domain becomes a hole.
    Collisions surface as transport failures (clip / undefined), never as
    silent misplacement.
  - Construction sites never name a per-coord builder directly:
    `for_coord/4` dispatches on the track's `coord_domain/0` through the
    builder table below, and `supported_coords/0` derives from the same
    table, so the mount-time guard and the construction sites can never
    disagree.

  ## Frame space

  Two distinct facilities share the `:frame` coordinate:

  - `frame/2` (dispatched via `for_coord/4` on frame-domain tracks): the
    same non-ripple construction as `tick/2` — an audio track's spans are
    already frame coordinates, so no tempo knowledge is involved.
  - `frame_over_tick/3` (dispatched on tick-domain tracks when the context
    carries a tempo pair and frame rate): the design doc §5 item-4
    composition `W_frame = T_new ∘ W_tick ∘ T_old⁻¹` for frame-addressed,
    score-following anchors. The `T_old`/`T_new` pair is located through
    the track's version clock (`Coconut.Edit.Workspace.warp_context/2`),
    which is what makes the composition exact across interleaved tempo
    edits. `tempo_shift/5` is the pure `T_new ∘ T_old⁻¹` warp backing the
    echo transport that runs after a tempo-track batch: a tempo edit adds
    no entry to other tracks' logs, yet frame anchors must still follow it.

  ## Caveats

  - WarpProvider turns `ops + span snapshots` into warps; it is a pure
    function of its inputs. Ripple mode (v2) adds non-identity logic on
    top.
  - The closure returns `{:ok, warp}` on success and
    `{:error, {:warp_construction_failed, reason}}` when the folded pieces
    cannot form a legal warp — tamale's transport aborts the fold and
    surfaces it as a transport failure (dead patch), never a crash. The
    coord must still be guarded before invoking: `Coconut.Edit.Patch.new/1`
    rejects Metric anchors outside `supported_coords/0` at construction
    time.
  - Warp pieces are exact rational coordinates (`Tamale.Coord` rejects
    floats), so the tempo conversion in `frame_over_tick/3` is built from
    integer milli-bpm steps — never from `Coconut.Score.TempoMap`, whose
    seconds are floats. Non-linear tempo segments are
    excluded by the same constraint (tempo-curve design doc §4).
  """

  alias Coconut.Score.Tick
  alias Tamale.Coord
  alias Tamale.Op.{Delete, Retime}
  alias Tamale.Warp

  @doc """
  Returns a `warp_provider` closure for the `:tick` coordinate system.

  `track_spans` is the track's versioned span table (see
  `Track.spans/1`). `patches` should be the track's live patches:
  their Metric coordinates extend the warp domain so every live anchor is
  covered.
  """
  @spec tick(map(), [Coconut.Edit.Patch.t()]) :: Tamale.Transport.warp_provider()
  def tick(track_spans, patches \\ []) do
    fn :tick, {version, ops} -> build_warp(track_spans, patches, version, ops) end
  end

  @doc """
  Returns a `warp_provider` closure for the `:frame` coordinate system.

  Same non-ripple construction as `tick/2`, for frame-domain tracks
  (audio): the track's spans and the batch's spans are already frame
  coordinates, so no tempo knowledge is involved.
  """
  @spec frame(map(), [Coconut.Edit.Patch.t()]) :: Tamale.Transport.warp_provider()
  def frame(track_spans, patches \\ []) do
    fn :frame, {version, ops} -> build_warp(track_spans, patches, version, ops) end
  end

  # coord → builder 表：supported_coords/0 从它推导（Patch.new 的挂载守卫
  # 来源）。for_coord/4 的 dispatch 在其上叠加上下文：tick 域轨拿到
  # tempo/帧率上下文时额外服务 :frame（T 对组合），无上下文时 :frame
  # 可见失败而非崩溃。
  @builders %{frame: &__MODULE__.frame/2, tick: &__MODULE__.tick/2}

  @doc """
  Coordinate systems this provider can serve — the keys of the builder
  dispatch table, sorted for determinism.

  `Coconut.Edit.Patch.new/1` rejects Metric anchors outside this list at
  construction time — that guard is what keeps each single-coord provider
  closure total in practice.
  """
  @spec supported_coords() :: [atom()]
  def supported_coords, do: @builders |> Map.keys() |> Enum.sort()

  @doc """
  Returns the `warp_provider` closure for a track with coordinate domain
  `coord`, or `nil` for an unknown coordinate system.

  Construction sites (write-time: `Coconut.Edit.Workspace`; check-time:
  `Coconut.Render.Resolve`) dispatch on the track's `coord_domain/0` through
  here, passing a `frame_context()` (built by
  `Coconut.Edit.Workspace.warp_context/2`) when available. A tick-domain
  closure then also serves `:frame` anchors via the `frame_over_tick/3`
  composition; without the context, a `:frame` call returns
  `{:error, :warp_provider_required}` — a surfaced transport failure
  (dead patch), never a clause-less-closure crash. A `nil` return plugs
  into `Track.transport_patches/2`'s nil semantics the same way.
  """
  @spec for_coord(atom(), map(), [Coconut.Edit.Patch.t()], frame_context() | map()) ::
          Tamale.Transport.warp_provider() | nil
  def for_coord(coord, track_spans, patches \\ [], context \\ %{})

  def for_coord(:tick, track_spans, patches, context) do
    native = tick(track_spans, patches)

    case context do
      %{tempo_pair_at: _, frame_rate: _, tpqn: _} ->
        composed = frame_over_tick(track_spans, patches, context)

        fn
          :tick, entry -> native.(:tick, entry)
          :frame, entry -> composed.(:frame, entry)
        end

      _incomplete ->
        fn
          :tick, entry -> native.(:tick, entry)
          :frame, _entry -> {:error, :warp_provider_required}
        end
    end
  end

  def for_coord(:frame, track_spans, patches, _context), do: frame(track_spans, patches)

  def for_coord(_coord, _track_spans, _patches, _context), do: nil

  @typedoc """
  Exact tempo step events for `frame_over_tick/3`: `{start_tick, milli_bpm}`
  pairs sorted by tick, the first at tick 0 — the same data the tempo
  track stores (`%{bpm: milli_bpm}` elements), kept exact because warp
  coordinates reject floats.
  """
  @type tempo_steps :: [{Tick.numeric_tick(), pos_integer()}]

  @typedoc """
  Context for `frame_over_tick/3`:

  - `:tempo_pair_at` — `(Tamale.version() -> {tempo_steps(), tempo_steps()} | nil)`.
    Given a log entry's (Space-private) version, returns the exact tempo
    steps before and after the gesture that committed it — the
    `T_old`/`T_new` pair of the composition (design doc §5 item 4).
    `nil` when the version cannot be dated or either side has no tempo
    events. Construction sites build the closure from the workspace's
    version clocks (`Coconut.Edit.Workspace.warp_context/2`).
  - `:frame_rate` — frames per second as an exact `Tamale.Coord.input()`
    (integer or `{num, den}`; floats are rejected).
  - `:tpqn` — ticks per quarter note.
  """
  @type frame_context :: %{
          required(:tempo_pair_at) => (Tamale.version() -> {tempo_steps(), tempo_steps()} | nil),
          required(:frame_rate) => Coord.input(),
          required(:tpqn) => pos_integer()
        }

  @doc """
  Returns a `:frame`-serving `warp_provider` over a **tick-domain** log:
  `W_frame = T_new ∘ W_tick ∘ T_old⁻¹` (design doc §5 item 4).

  `T_old`/`T_new` are tick→frame staircases built from the exact milli-bpm
  step pairs returned by `context.tempo_pair_at` and `context.frame_rate`.
  When the tempo did not change across the folded entries the pair is
  equal and the composition degenerates to `T ∘ W_tick ∘ T⁻¹`.

  The composed warp covers every live frame anchor by construction: the
  tick bound is extended by the anchors' worst-case tick preimage under
  either tempo state (the fastest step consumes the most ticks per frame),
  and each `T`'s final slope extends to that bound. Missing/empty tempo
  steps, malformed steps, or a non-exact `frame_rate` are construction
  errors (`:missing_tempo_events` / `:invalid_tempo_steps` /
  `:invalid_frame_rate` under `:warp_construction_failed`), surfacing as
  transport failures like any other warp error.
  """
  @spec frame_over_tick(map(), [Coconut.Edit.Patch.t()], frame_context()) ::
          Tamale.Transport.warp_provider()
  def frame_over_tick(track_spans, patches, %{
        tempo_pair_at: tempo_pair_at,
        frame_rate: frame_rate,
        tpqn: tpqn
      }) do
    fn :frame, {version, ops} ->
      frame_warp_for_entry(track_spans, patches, tempo_pair_at, frame_rate, tpqn, version, ops)
    end
  end

  @doc """
  The pure tempo-change warp `T_new ∘ T_old⁻¹` over the given patches'
  frame-anchor domain — the echo-transport warp for a tempo-track batch
  (design doc §5 item 4): frame Metric anchors on tick-domain tracks
  follow a tempo edit even though their own track's log gained no entry.

  Equal step sets short-circuit to `Warp.identity()`. Domain coverage uses
  the same worst-case preimage bound as `frame_over_tick/3`, under both
  tempo states.
  """
  @spec tempo_shift(
          tempo_steps() | nil,
          tempo_steps() | nil,
          Coord.input(),
          pos_integer(),
          [Coconut.Edit.Patch.t()]
        ) :: {:ok, Warp.t()} | {:error, {:warp_construction_failed, term()}}
  def tempo_shift(steps_old, steps_new, frame_rate, tpqn, patches) do
    with {:ok, fps} <- cast_frame_rate(frame_rate),
         {:ok, steps_old} <- check_tempo_steps(steps_old),
         {:ok, steps_new} <- check_tempo_steps(steps_new) do
      if steps_old == steps_new do
        {:ok, Warp.identity()}
      else
        do_tempo_shift(steps_old, steps_new, fps, tpqn, patches)
      end
    end
  end

  defp do_tempo_shift(steps_old, steps_new, fps, tpqn, patches) do
    upper =
      Enum.reduce([steps_old, steps_new], Coord.new(0), fn steps, acc ->
        Coord.max(acc, tick_preimage_bound(patches, steps, fps, tpqn))
      end)

    with {:ok, t_old} <- tempo_warp(steps_old, fps, tpqn, upper),
         {:ok, t_new} <- tempo_warp(steps_new, fps, tpqn, upper) do
      {:ok, Warp.compose(t_new, Warp.invert(t_old))}
    end
  end

  # ---- Frame-over-tick composition (§5 item 4) ----

  defp frame_warp_for_entry(track_spans, patches, tempo_pair_at, frame_rate, tpqn, version, ops) do
    case batch_intents(track_spans, version, ops) do
      [] ->
        {:ok, Warp.identity()}

      intents ->
        with {:ok, {steps_old, steps_new}} <- fetch_tempo_pair(tempo_pair_at, version),
             {:ok, fps} <- cast_frame_rate(frame_rate) do
          compose_frame_warp(track_spans, patches, intents, steps_old, steps_new, fps, tpqn)
        end
    end
  end

  # W_frame = T_new ∘ W_tick ∘ T_old⁻¹：tick 定义域上界先扩到所有 frame
  # 锚在两端 tempo 下的最坏原像，再在同一上界上构造 W_tick 与两个 T。
  defp compose_frame_warp(track_spans, patches, intents, steps_old, steps_new, fps, tpqn) do
    {lower, upper} =
      frame_domain(track_spans, patches, intents, [steps_old, steps_new], fps, tpqn)

    with {:ok, w_tick} <- warp_from_intents(intents, lower, upper),
         {:ok, t_old} <- tempo_warp(steps_old, fps, tpqn, upper),
         {:ok, t_new} <- tempo_warp(steps_new, fps, tpqn, upper) do
      {:ok, Warp.compose(t_new, Warp.compose(w_tick, Warp.invert(t_old)))}
    end
  end

  defp fetch_tempo_pair(tempo_pair_at, version) do
    case tempo_pair_at.(version) do
      {steps_old, steps_new} ->
        with {:ok, steps_old} <- check_tempo_steps(steps_old),
             {:ok, steps_new} <- check_tempo_steps(steps_new) do
          {:ok, {steps_old, steps_new}}
        end

      _undated ->
        {:error, {:warp_construction_failed, :missing_tempo_events}}
    end
  end

  # 合法形状与 tempo 轨的存储不变式一致：首事件在 tick 0（TempoMap.compile
  # 的 first-at-zero 规则）、tick 严格递增、milli-bpm 为正整数。
  defp check_tempo_steps(nil), do: {:error, {:warp_construction_failed, :missing_tempo_events}}
  defp check_tempo_steps([]), do: {:error, {:warp_construction_failed, :missing_tempo_events}}

  defp check_tempo_steps([{0, milli} | _] = steps) when is_integer(milli) and milli > 0 do
    if Enum.all?(steps, &valid_step?/1) and strictly_ascending?(Enum.map(steps, &elem(&1, 0))) do
      {:ok, steps}
    else
      {:error, {:warp_construction_failed, :invalid_tempo_steps}}
    end
  end

  defp check_tempo_steps(_steps), do: {:error, {:warp_construction_failed, :invalid_tempo_steps}}

  defp valid_step?({tick, milli}),
    do: is_integer(tick) and tick >= 0 and is_integer(milli) and milli > 0

  defp valid_step?(_other), do: false

  defp strictly_ascending?(ticks) do
    ticks
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> b > a end)
  end

  defp cast_frame_rate(rate) do
    case Coord.cast(rate) do
      {:ok, coord} ->
        if Coord.gt?(coord, Coord.new(0)),
          do: {:ok, coord},
          else: {:error, {:warp_construction_failed, :invalid_frame_rate}}

      {:error, _} ->
        {:error, {:warp_construction_failed, :invalid_frame_rate}}
    end
  end

  # 复合 warp 的 tick 定义域：常规上界与所有 frame 锚的最坏 tick 原像
  # 取大（最快档 = 最大 milli-bpm 每帧消耗 tick 最多），T 的末段斜率
  # 延伸到该上界，保证 T⁻¹(anchor) 与 W_tick 的像都落在 T 的定义域内。
  # steps_list 为对组合的两端 tempo（单 tempo 场景传一个元素的列表）。
  defp frame_domain(track_spans, patches, intents, steps_list, fps, tpqn) do
    {lower, upper} = domain(track_spans, patches, intents)

    upper =
      Enum.reduce(steps_list, upper, fn steps, acc ->
        Coord.max(acc, tick_preimage_bound(patches, steps, fps, tpqn))
      end)

    {lower, upper}
  end

  defp tick_preimage_bound(patches, steps, fps, tpqn) do
    max_frame =
      patches
      |> frame_anchor_coords()
      |> Enum.reduce(Coord.new(0), &Coord.max/2)

    max_milli = steps |> Enum.map(&elem(&1, 1)) |> Enum.max()

    # ticks per frame = (milli × tpqn) / (60_000 × fps)
    Coord.divide(
      Coord.mul(max_frame, Coord.new(max_milli * tpqn)),
      Coord.mul(Coord.new(60_000), fps)
    )
  end

  defp frame_anchor_coords(patches) do
    patches
    |> Enum.flat_map(fn
      %{anchor: %Tamale.Anchor.Metric{coord: :frame, from: from, to: to}} -> [from, to]
      _other -> []
    end)
    |> Enum.map(&Coord.cast!/1)
  end

  # T：tick→frame 阶梯 warp。每段斜率（frames/tick）= fps × 60_000 /
  # (milli × tpqn)，全部精确有理数；段界取事件边界与 t_upper 的截断，
  # 末段斜率延伸铺满 [0, t_upper]。
  defp tempo_warp(steps, fps, tpqn, t_upper) do
    pieces =
      steps
      |> Enum.map(fn {tick, milli} -> {Coord.new(tick), milli} end)
      |> tempo_pieces(fps, tpqn, t_upper, Coord.new(0), [])
      |> Enum.map(fn {{t0, t1}, {f0, f1}} -> {t0, t1, f0, f1} end)

    from_segments(pieces)
  end

  defp tempo_pieces([], _fps, _tpqn, _t_upper, _f_cur, acc), do: Enum.reverse(acc)

  defp tempo_pieces([{t_cur, milli} | rest], fps, tpqn, t_upper, f_cur, acc) do
    t_stop =
      case rest do
        [{t_next, _} | _] -> Coord.min(t_next, t_upper)
        [] -> t_upper
      end

    if Coord.lt?(t_cur, t_stop) do
      rate = frames_per_tick(milli, fps, tpqn)
      f_stop = Coord.add(f_cur, Coord.mul(rate, Coord.sub(t_stop, t_cur)))

      tempo_pieces(rest, fps, tpqn, t_upper, f_stop, [{{t_cur, t_stop}, {f_cur, f_stop}} | acc])
    else
      # 事件边界已越过 t_upper：截断收尾（rest 为空时殊途同归）
      Enum.reverse(acc)
    end
  end

  defp frames_per_tick(milli, {fps_num, fps_den}, tpqn),
    do: Coord.new(60_000 * fps_num, milli * tpqn * fps_den)

  # ---- Batch warp construction (v1: non-ripple) ----

  defp build_warp(track_spans, patches, version, ops) do
    case batch_intents(track_spans, version, ops) do
      [] ->
        {:ok, Warp.identity()}

      intents ->
        {lower, upper} = domain(track_spans, patches, intents)
        warp_from_intents(intents, lower, upper)
    end
  end

  defp batch_intents(track_spans, version, ops) do
    old_spans = spans_at(track_spans, version - 1)

    ops
    |> Enum.flat_map(&intent(&1, old_spans))
    |> Enum.uniq()
  end

  defp warp_from_intents(intents, lower, upper) do
    intents
    |> merge_overlaps()
    |> tile(lower, upper)
    |> enforce_monotone()
    |> from_segments()
  end

  # One warp intent per op. Retime is self-contained (the op carries both
  # spans); Delete needs the pre-batch span table. A zero-length Retime
  # target is a hole, not a degenerate segment.
  defp intent(%Retime{old_span: {o0, o1}, new_span: {n0, n1}}, _old_spans) do
    old = {Coord.cast!(o0), Coord.cast!(o1)}
    new = {Coord.cast!(n0), Coord.cast!(n1)}

    cond do
      not Coord.lt?(elem(old, 0), elem(old, 1)) -> []
      not Coord.lt?(elem(new, 0), elem(new, 1)) -> [{:hole, old}]
      true -> [{:segment, old, new}]
    end
  end

  defp intent(%Delete{id: id}, old_spans) do
    case Map.fetch(old_spans, id) do
      {:ok, {s, e}} -> [{:hole, {Coord.cast!(s), Coord.cast!(e)}}]
      :error -> []
    end
  end

  defp intent(_op, _old_spans), do: []

  # Latest span snapshot at or before `version` — Move-only batches write no
  # snapshot, so version keys are sparse.
  defp spans_at(track_spans, version) do
    track_spans
    |> Map.keys()
    |> Enum.filter(&(&1 <= version))
    |> Enum.max(fn -> nil end)
    |> case do
      nil -> %{}
      v -> Map.fetch!(track_spans, v)
    end
  end

  # The warp domain must cover every coordinate a fold can ask about: all
  # span snapshots, the batch's own spans, and all live Metric anchors.
  defp domain(track_spans, patches, intents) do
    span_coords =
      for {_v, spans} <- track_spans, {s, e} <- Map.values(spans), x <- [s, e], do: x

    anchor_coords =
      Enum.flat_map(patches, fn
        %{anchor: %Tamale.Anchor.Metric{from: from, to: to}} -> [from, to]
        _ -> []
      end)

    intent_coords =
      Enum.flat_map(intents, fn
        {:segment, {o0, o1}, {n0, n1}} -> [o0, o1, n0, n1]
        {:hole, {o0, o1}} -> [o0, o1]
      end)

    coords = Enum.map([0 | span_coords ++ anchor_coords ++ intent_coords], &Coord.cast!/1)
    zero = Coord.cast!(0)

    {Enum.reduce(coords, zero, &Coord.min/2), Enum.reduce(coords, zero, &Coord.max/2)}
  end

  # Overlapping affected old-domains cannot map one region two ways:
  # collapse the union into a hole. Touching intervals stay separate.
  # Sort is a total, deterministic order (start, end, shape) — a non-strict
  # comparator on starts alone would leave equal-start ties input-dependent.
  defp merge_overlaps(intents) do
    intents
    |> Enum.sort_by(fn intent ->
      {elem(old_span(intent), 0), elem(old_span(intent), 1), intent_rank(intent)}
    end)
    |> Enum.reduce([], &add_intent/2)
    |> Enum.reverse()
  end

  defp intent_rank({:hole, _}), do: 0
  defp intent_rank({:segment, _, _}), do: 1

  defp add_intent(intent, []) do
    [intent]
  end

  defp add_intent(intent, [prev | rest] = acc) do
    {o0, o1} = old_span(intent)
    {h0, h1} = old_span(prev)

    if Coord.lt?(o0, h1) do
      [{:hole, {Coord.min(h0, o0), Coord.max(h1, o1)}} | rest]
    else
      [intent | acc]
    end
  end

  defp old_span({:segment, old, _new}), do: old
  defp old_span({:hole, old}), do: old

  # Tile [lower, upper]: identity pieces for the unaffected gaps, segment
  # pieces for Retimes, nothing for holes.
  defp tile(affected, lower, upper) do
    {pieces, cursor} =
      Enum.map_reduce(affected, lower, fn
        {:segment, {o0, o1}, {n0, n1}}, cursor ->
          {gap_piece(cursor, o0) ++ [{o0, o1, n0, n1}], o1}

        {:hole, {o0, o1}}, cursor ->
          {gap_piece(cursor, o0), o1}
      end)

    Enum.concat(pieces) ++ gap_piece(cursor, upper)
  end

  defp gap_piece(cursor, stop) do
    if Coord.lt?(cursor, stop), do: [{cursor, stop, cursor, stop}], else: []
  end

  # A warp is monotone by definition. Walking pieces in old-domain order,
  # the first piece to claim an image region keeps it: later identity pieces
  # are truncated at the watermark, later segments drop out (their domain
  # becomes a hole).
  defp enforce_monotone(pieces) do
    {kept, _watermark} =
      Enum.map_reduce(pieces, nil, fn {o0, o1, n0, n1} = piece, wm ->
        cond do
          wm == nil or Coord.gte?(n0, wm) ->
            {[piece], n1}

          o0 == n0 and o1 == n1 and Coord.lt?(wm, o1) ->
            # identity piece colliding with an earlier image: truncate it
            {[{wm, o1, wm, o1}], o1}

          true ->
            {[], wm}
        end
      end)

    Enum.concat(kept)
  end

  defp from_segments(pieces) do
    segments = Enum.map(pieces, fn {o0, o1, n0, n1} -> {{o0, o1}, {n0, n1}} end)

    case Warp.from_segments(segments) do
      {:ok, warp} ->
        {:ok, warp}

      {:error, reason} ->
        {:error, {:warp_construction_failed, reason}}
    end
  end
end
