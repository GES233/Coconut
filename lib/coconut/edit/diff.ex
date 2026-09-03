defmodule Coconut.Edit.Diff do
  @moduledoc """
  Diff adapter: infers an op sequence from before/after element snapshots
  (design doc §8).

  The normal write path is gesture → op batch. File import (MIDI/UST),
  wholesale external rewrites, and block paste only hand you the *resulting*
  state, so this module reverse-engineers the six ops from an old track
  snapshot and a new element list. All uncertainty is quarantined in this
  one function; every other path stays pure ops.

  ## Matching (settled 2026-08-11)

  Two passes, conservative fallback:

  1. **Exact composite key** — `(span, content)` identical pairs keep the
     old id. Content is the cast element minus its id, so any track module
     works (the skeleton is generic; only Vocal is blessed by tests).
  2. **Mutual-best span overlap** — an unmatched old/new pair is accepted
     only when each is the other's strict best candidate (by overlap, then
     start proximity). The pair keeps the old id: a span change becomes a
     `Retime`, a sequence change a `Move`, and a content difference a
     side-table upsert (content edits never produce ops, §7).

  Everything else is **Delete + Insert with a fresh id** — never a guessed
  identity. A wrong `Retime`/`Move` would silently carry a patch's payload
  onto the wrong note; Delete + Insert kills the id and the patch dies
  *visibly* into the graveyard, where the policy layer can re-mount it
  (tamale's "surfaced, never silent" rule).

  ## Output and caller duties

  The output is plain `[Tamale.Op.t()]` + `Coconut.Edit.Operation.side_changes()`,
  applied through the same `Workspace.apply_batch/5` pipe as any gesture
  (callers pass their usual `expected_version`). An unchanged track yields
  `{:ok, [], empty_changes}` — callers may skip the apply.

  Gesture-specific policy is bypassed by design, but
  `Workspace.apply_batch/5` still checks whole-track invariants (for example
  Vocal same-track non-overlap) before committing. New elements are cast
  through the track module's `cast_element/3`, so malformed content is
  rejected here.
  """

  alias Coconut.Edit.{Operation, Track}
  alias Coconut.Edit.Operations.CoreComponents
  alias Coconut.Util.ID

  @typedoc "One new-state element: its span in the track's domain plus raw attrs (the `cast_element/3` vocabulary)."
  @type new_element :: {Track.span(), attrs :: map()}

  @doc """
  Diff a track's current state against `new_elements` (the target sequence,
  in order) and return the op batch plus side changes that would turn the
  former into the latter.
  """
  @spec diff(Track.t(), [new_element()]) ::
          {:ok, [Tamale.Op.t()], Operation.side_changes()} | {:error, term()}
  def diff(%Track{} = track, new_elements) when is_list(new_elements) do
    with {:ok, news} <- cast_news(track, new_elements) do
      olds = Track.view(track)

      {pairs, rest_olds, rest_news} = exact_match(olds, news)
      {pairs, rest_olds, rest_news} = overlap_match(pairs, rest_olds, rest_news)

      deletes = Enum.map(rest_olds, fn {id, _element, _span} -> id end)
      inserts = Map.new(rest_news, fn new -> {new.idx, ID.generate_id("El_")} end)

      ops =
        delete_ops(deletes) ++
          retime_ops(olds, news, pairs) ++
          sequence_ops(final_ids(news, pairs, inserts), track.space.ids, deletes, inserts)

      {:ok, ops, side_changes(olds, news, pairs, deletes, inserts)}
    end
  end

  # ---- Casting ----

  # 新元素经轨型模块重铸：内容合法性在此把关。临时 id 只用于铸造，匹配
  # 结算后替换为旧 id（配对）或新铸 id（插入）。
  defp cast_news(track, new_elements) do
    new_elements
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{span, attrs}, idx}, {:ok, acc} ->
      case Track.cast_element(track, "diff:new:#{idx}", span, attrs) do
        {:ok, element} -> {:cont, {:ok, [%{idx: idx, span: span, element: element} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, news} -> {:ok, Enum.reverse(news)}
      error -> error
    end
  end

  # ---- Pass 1: exact composite key (span + content) ----

  defp exact_match(olds, news) do
    {pairs, rest_olds, rest_news} = Enum.reduce(news, {[], olds, []}, &match_one_new/2)

    {Enum.reverse(pairs), rest_olds, Enum.reverse(rest_news)}
  end

  defp match_one_new(new, {pairs, free_olds, rest_news}) do
    key = {new.span, content_key(new.element)}

    case Enum.find(free_olds, fn {_id, element, span} -> {span, content_key(element)} == key end) do
      {old_id, _element, _span} ->
        {[{old_id, new.idx} | pairs], reject_old(free_olds, old_id), rest_news}

      nil ->
        {pairs, free_olds, [new | rest_news]}
    end
  end

  # ---- Pass 2: mutual-best span overlap, strict ----

  # 互为最优才配对：任一方向出现平分（重叠与 start 距离皆同）即放弃，
  # 落入 Delete + Insert——宁可判死可见，也不错认身份。
  defp overlap_match(pairs, rest_olds, rest_news) do
    accepted =
      for {old_id, _element, old_span} <- rest_olds,
          best_idx = strict_best(old_span, rest_news, fn new -> new.idx end),
          best_idx != nil,
          mutual?(old_id, best_idx, rest_news, rest_olds),
          do: {old_id, best_idx}

    accepted_old_ids = Enum.map(accepted, &elem(&1, 0))
    accepted_new_idxs = Enum.map(accepted, &elem(&1, 1))

    {pairs ++ accepted, Enum.reject(rest_olds, fn old -> elem(old, 0) in accepted_old_ids end),
     Enum.reject(rest_news, fn new -> new.idx in accepted_new_idxs end)}
  end

  # candidates 中按 score 严格最优的项的 key（经 key_of 取出）；无候选
  # 或并列最优 → nil。
  defp strict_best(span, candidates, key_of) do
    candidates
    |> Enum.map(fn cand -> {key_of.(cand), score(span, cand_span(cand))} end)
    |> Enum.filter(fn {_key, score} -> score > {0, 0} end)
    |> Enum.sort_by(fn {_key, score} -> score end, &>=/2)
    |> case do
      [] -> nil
      [{key, top} | rest] -> if match?([{_, ^top} | _], rest), do: nil, else: key
    end
  end

  # 互为最优才成立：new 一侧在剩余 olds 中的严格最优也必须是这个 old。
  defp mutual?(old_id, new_idx, rest_news, rest_olds) do
    new = Enum.find(rest_news, &(&1.idx == new_idx))
    strict_best(new.span, rest_olds, fn {id, _element, _span} -> id end) == old_id
  end

  defp cand_span({_id, _element, span}), do: span
  defp cand_span(%{span: span}), do: span

  # 分数 = {重叠长度, -start 距离}：重叠相同者 start 更近者胜；tuple 比较
  # 由 Elixir 项序保证确定。
  defp score(old_span, new_span) do
    case overlap(old_span, new_span) do
      0 -> {0, 0}
      ov -> {ov, -abs(elem(old_span, 0) - elem(new_span, 0))}
    end
  end

  defp overlap({s1, e1}, {s2, e2}), do: max(0, min(e1, e2) - max(s1, s2))

  # ---- Ops ----

  defp delete_ops(deletes), do: Enum.map(deletes, &%Tamale.Op.Delete{id: &1})

  # 配对成功且 span 变化 → Retime（op 自足，携带新旧 span）。
  defp retime_ops(olds, news, pairs) do
    for {old_id, new_idx} <- pairs,
        old_span = fetch_old_span(olds, old_id),
        new = Enum.at(news, new_idx),
        old_span != new.span,
        do: %Tamale.Op.Retime{id: old_id, old_span: old_span, new_span: new.span}
  end

  # 目标序列：按 new 列表顺序，配对者用旧 id，插入者用新铸 id。
  defp final_ids(news, pairs, inserts) do
    pair_by_new = Map.new(pairs, fn {old_id, new_idx} -> {new_idx, old_id} end)

    Enum.map(news, fn new ->
      Map.get(pair_by_new, new.idx) || Map.fetch!(inserts, new.idx)
    end)
  end

  # 从左到右把当前序列编辑成目标序列：已就位跳过，在轨的 Move，新来
  # 的 Insert；after_id 永远是上一步已就位的元素（开头为 :head）。
  defp sequence_ops(final_ids, current_ids, deletes, inserts) do
    deleted = MapSet.new(deletes)
    current = Enum.reject(current_ids, &MapSet.member?(deleted, &1))
    insert_ids = inserts |> Map.values() |> MapSet.new()

    {ops, _final} =
      final_ids
      |> Enum.with_index()
      |> Enum.reduce({[], current}, fn {id, k}, acc ->
        place_step(acc, id, k, final_ids, insert_ids)
      end)

    Enum.reverse(ops)
  end

  defp place_step({ops, cur}, id, k, final_ids, insert_ids) do
    if Enum.at(cur, k) == id do
      {ops, cur}
    else
      after_id = if k == 0, do: :head, else: Enum.at(final_ids, k - 1)

      if MapSet.member?(insert_ids, id) do
        {[%Tamale.Op.Insert{id: id, after_id: after_id} | ops], List.insert_at(cur, k, id)}
      else
        {[%Tamale.Op.Move{id: id, after_id: after_id} | ops],
         cur |> List.delete(id) |> List.insert_at(k, id)}
      end
    end
  end

  # ---- Side changes ----

  defp side_changes(olds, news, pairs, deletes, inserts) do
    pair_by_new = Map.new(pairs, fn {old_id, new_idx} -> {new_idx, old_id} end)
    old_by_id = Map.new(olds, fn {id, element, span} -> {id, {element, span}} end)

    changes = CoreComponents.empty_side_changes()

    news
    |> Enum.reduce(changes, fn new, acc ->
      case Map.fetch(pair_by_new, new.idx) do
        {:ok, old_id} -> matched_change(acc, old_id, new, Map.fetch!(old_by_id, old_id))
        :error -> insert_change(acc, Map.fetch!(inserts, new.idx), new)
      end
    end)
    |> then(fn acc ->
      Enum.reduce(deletes, acc, fn id, acc ->
        %{
          acc
          | elements: Map.put(acc.elements, id, :delete),
            span_snapshot: Map.put(acc.span_snapshot, id, :delete)
        }
      end)
    end)
  end

  # 配对成功：span 变 → span_snapshot upsert；内容变 → 元素 upsert
  # （沿用旧 id）。两者皆无则不动。
  defp matched_change(acc, old_id, new, {old_element, old_span}) do
    acc =
      if old_span != new.span,
        do: %{acc | span_snapshot: Map.put(acc.span_snapshot, old_id, new.span)},
        else: acc

    if content_key(old_element) != content_key(new.element),
      do: %{acc | elements: Map.put(acc.elements, old_id, put_element_id(new.element, old_id))},
      else: acc
  end

  defp insert_change(acc, fresh_id, new) do
    %{
      acc
      | elements: Map.put(acc.elements, fresh_id, put_element_id(new.element, fresh_id)),
        span_snapshot: Map.put(acc.span_snapshot, fresh_id, new.span)
    }
  end

  # ---- Small helpers ----

  # 内容键 = 去掉 id 的元素（struct 转裸 map）。同一轨型的同内容元素
  # 必有相同内容键；跨轨型比较不会发生（diff 以单轨为输入）。
  defp content_key(%_struct{} = element), do: element |> Map.from_struct() |> Map.delete(:id)
  defp content_key(element) when is_map(element), do: element

  defp put_element_id(element, id) when is_map(element) do
    if Map.has_key?(element, :id), do: Map.put(element, :id, id), else: element
  end

  defp fetch_old_span(olds, id) do
    {_id, _element, span} = Enum.find(olds, fn old -> elem(old, 0) == id end)
    span
  end

  defp reject_old(olds, id), do: Enum.reject(olds, fn old -> elem(old, 0) == id end)
end
