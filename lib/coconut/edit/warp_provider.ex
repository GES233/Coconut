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
    `for_coord/3` dispatches on the track's `coord_domain/0` through the
    builder table below, and `supported_coords/0` derives from the same
    table, so the mount-time guard and the construction sites can never
    disagree.

  ## Caveats

  - WarpProvider turns `ops + span snapshots` into warps; it is a pure
    function of its inputs. Ripple mode (v2) and frame-space warp add
    non-identity logic on top.
  - The closure returns `{:ok, warp}` on success and
    `{:error, {:warp_construction_failed, reason}}` when the folded pieces
    cannot form a legal warp — tamale's transport aborts the fold and
    surfaces it as a transport failure (dead patch), never a crash. The
    coord must still be guarded before invoking: `Coconut.Edit.Patch.new/1`
    rejects Metric anchors outside `supported_coords/0` at construction
    time.
  """

  alias Tamale.Coord
  alias Tamale.Op.{Delete, Retime}
  alias Tamale.Warp

  @doc """
  Returns a `warp_provider` closure for the `:tick` coordinate system.

  `track_spans` is the track's versioned span table (see
  `Workspace.track_spans/2`). `patches` should be the track's live patches:
  their Metric coordinates extend the warp domain so every live anchor is
  covered.
  """
  @spec tick(map(), [Coconut.Edit.Patch.t()]) :: Tamale.Transport.warp_provider()
  def tick(track_spans, patches \\ []) do
    fn :tick, {version, ops} -> build_warp(track_spans, patches, version, ops) end
  end

  # coord → builder dispatch table, the single place naming coordinate
  # systems: supported_coords/0 derives from it and for_coord/3 dispatches
  # through it, so a new coordinate system (frame warp, design doc §11.2
  # v2) is one entry here. The frame builder will need the tempo map
  # (W_frame = T_new ∘ W_tick ∘ T_old⁻¹), which the (spans, patches)
  # builder shape does not carry — revisit the entry signature when it
  # lands rather than guessing it now.
  @builders %{tick: &__MODULE__.tick/2}

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
  Returns the `warp_provider` closure serving `coord`, or `nil` when the
  dispatch table has no builder for it.

  Construction sites (write-time: `Coconut.Edit.Workspace`; check-time:
  `Coconut.Render.Resolve`) dispatch on the track's `coord_domain/0` through
  here. A `nil` return plugs into `Workspace.transport_patches/3`'s nil
  semantics: Ordinal/Relative anchors still travel by identity, while a
  `Tamale.Anchor.Metric` anchor dies as `:warp_provider_required` — a
  surfaced transport failure instead of a clause-less-closure crash. Via
  `Coconut.Edit.Patch.new/1` the Metric case is unreachable anyway (its guard
  derives from the same table).
  """
  @spec for_coord(atom(), map(), [Coconut.Edit.Patch.t()]) ::
          Tamale.Transport.warp_provider() | nil
  def for_coord(coord, track_spans, patches \\ []) do
    case Map.fetch(@builders, coord) do
      {:ok, builder} -> builder.(track_spans, patches)
      :error -> nil
    end
  end

  # ---- Batch warp construction (v1: non-ripple) ----

  defp build_warp(track_spans, patches, version, ops) do
    old_spans = spans_at(track_spans, version - 1)

    intents =
      ops
      |> Enum.flat_map(&intent(&1, old_spans))
      |> Enum.uniq()

    case intents do
      [] ->
        {:ok, Warp.identity()}

      _ ->
        {lower, upper} = domain(track_spans, patches, intents)

        intents
        |> merge_overlaps()
        |> tile(lower, upper)
        |> enforce_monotone()
        |> from_segments()
    end
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
