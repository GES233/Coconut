defmodule Coconut.Render.Resolve do
  @moduledoc """
  Bridge between the tamale edit kernel and the engine.

  Two stages, single entry point `run_check/3`:

  1. **Transport** — every patch's anchor travels along its track's op log.
     Transport failures (clip / ambiguous / undefined) become check entries.
  2. **Resolve** — surviving patches are judged per channel: the channel's
     `projection` produces the fresh base slice for the anchor region (a
     canonical term) and `Tamale.Patch.resolve/2` digests it and compares
     against the patch's `base_digest`. Conflicts become check entries.

  All entries are aggregated — no short-circuit — and a single entry vetoes
  the whole batch. Verdict semantics: `{:ok, verdict}` means the check
  **executed**; `passed: false` is the veto, carrying the aggregated
  `entries`. This stage never fails to execute, so there is no
  `{:error, _}` case here. On a pass the resolved payloads are folded into
  `%{port_ref => %{input: value}}` engine interventions via each channel's
  `target`.

  Channels are caller-supplied modules implementing
  `Coconut.Render.Channel`: digest projection shapes are domain policy,
  not kernel policy.
  """

  alias Coconut.Edit.{Patch, Track, WarpProvider, Workspace}

  @typedoc "Engine port reference: `{:port, node, port}`."
  @type port_ref :: {:port, node :: term(), port :: term()}

  @typedoc """
  Channel contract.

  - `projection` — produces the fresh base slice for a patch's anchor
    region: a canonical term (see `Tamale.Digest`). `Tamale.Patch.resolve/2`
    digests it and compares against `patch.patch.base_digest` with zero
    tolerance.
  - `target` — where a resolved payload lands: a single `port_ref`, or a
    function fanning the payload out to `[{port_ref, value}]` pairs.
  """
  @type channel_spec :: module()

  @typedoc "A single check failure. Entries are aggregated before vetoing."
  @type check_entry :: %{
          :kind => :conflict | :transport | :unknown_channel | :projection_failed,
          :track_id => Coconut.Edit.Track.track_id(),
          :patch => Patch.t(),
          optional(:channel) => atom(),
          optional(:reason) => term()
        }

  @doc """
  Run the two-stage check over every patch in the workspace.

  Returns `{:ok, %{passed: true, interventions: ..., survivors: ...}}` when
  all patches survive transport and resolve cleanly;
  `{:ok, %{passed: false, entries: entries}}` otherwise. `survivors` carry
  transported (up-to-date) anchors.
  """
  @spec run_check(Workspace.t(), %{atom() => channel_spec()}, keyword()) ::
          {:ok,
           %{
             passed: true,
             interventions: %{port_ref() => %{input: term()}},
             survivors: [Patch.t()]
           }
           | %{passed: false, entries: [check_entry()]}}
  def run_check(ws, channels, opts \\ [])

  def run_check(%Workspace{} = ws, channels, _opts) when is_map(channels) do
    {survivors, transport_entries} = transport_all(ws)
    {resolved, resolve_entries} = resolve_all(ws, survivors, channels)

    case transport_entries ++ resolve_entries do
      [] ->
        {:ok,
         %{passed: true, interventions: fold_resolved(resolved, channels), survivors: survivors}}

      entries ->
        {:ok, %{passed: false, entries: entries}}
    end
  end

  # ---- Transport stage ----

  # Patches live on their track, so "every patch in the workspace" is every
  # track's patch list (globals included, via `Workspace.all_tracks/1`);
  # an out-of-band mount on an unknown track is rejected at
  # `Workspace.attach_patch/2` and cannot occur here.
  defp transport_all(ws) do
    {surv_acc, entry_acc} =
      Enum.reduce(Workspace.all_tracks(ws), {[], []}, fn {_track_id, track},
                                                         {surv_acc, entry_acc} ->
        case track.patches do
          [] ->
            {surv_acc, entry_acc}

          patches ->
            provider =
              WarpProvider.for_coord(
                Track.coord_domain(track),
                Track.spans(track),
                patches,
                Workspace.warp_context(ws, track)
              )

            {:ok, survivors, dead} = Track.transport_patches(track, provider)
            entries = Enum.map(dead, &transport_entry(elem(&1, 0), elem(&1, 1)))

            {Enum.reverse(survivors, surv_acc), Enum.reverse(entries, entry_acc)}
        end
      end)

    {Enum.reverse(surv_acc), Enum.reverse(entry_acc)}
  end

  defp transport_entry(%Patch{} = patch, reason) do
    %{
      kind: :transport,
      track_id: patch.track_id,
      patch: patch,
      channel: patch.channel,
      reason: reason
    }
  end

  # ---- Resolve stage ----

  defp resolve_all(ws, survivors, channels) do
    {ok_acc, entry_acc} =
      Enum.reduce(survivors, {[], []}, &resolve_patch(&1, &2, ws, channels))

    {Enum.reverse(ok_acc), Enum.reverse(entry_acc)}
  end

  defp resolve_patch(patch, {ok_acc, entry_acc}, ws, channels) do
    case Map.fetch(channels, patch.channel) do
      :error ->
        entry = %{
          kind: :unknown_channel,
          track_id: patch.track_id,
          patch: patch,
          channel: patch.channel
        }

        {ok_acc, [entry | entry_acc]}

      {:ok, spec} ->
        case resolve_one(ws, patch, spec) do
          {:ok, payload} -> {[{patch, payload} | ok_acc], entry_acc}
          {:error, entry} -> {ok_acc, [entry | entry_acc]}
        end
    end
  end

  defp resolve_one(ws, %Patch{} = patch, spec) do
    # probe 期 channel（§6.6 身份/输出底料）：底料在 workspace 之外物化，
    # 静态 check 跳过 digest 裁决，直接放行 payload；引擎 probe 用
    # `Tamale.Patch.resolve/2` 对新底料重新裁决。
    if probe_stage?(spec) do
      {:ok, patch.patch.payload}
    else
      static_resolve(ws, patch, spec)
    end
  end

  defp probe_stage?(spec) do
    function_exported?(spec, :resolve_stage, 0) and spec.resolve_stage() == :probe
  end

  defp static_resolve(ws, %Patch{} = patch, spec) do
    with {:ok, fresh_base} <- spec.projection(ws, patch),
         {:ok, payload} <- Tamale.Patch.resolve(patch.patch, fresh_base) do
      {:ok, payload}
    else
      {:conflict, reason} ->
        {:error,
         %{
           kind: :conflict,
           track_id: patch.track_id,
           patch: patch,
           channel: patch.channel,
           reason: reason
         }}

      {:error, reason} ->
        {:error,
         %{
           kind: :projection_failed,
           track_id: patch.track_id,
           patch: patch,
           channel: patch.channel,
           reason: reason
         }}

      # Bare non-tuple failures (e.g. `Map.fetch/2`'s raw `:error` leaking
      # out of a channel projection) land here instead of crashing the
      # whole round with a CaseClauseError.
      other ->
        {:error,
         %{
           kind: :projection_failed,
           track_id: patch.track_id,
           patch: patch,
           channel: patch.channel,
           reason: other
         }}
    end
  end

  # ---- Fold ----

  # Mirrors equinox Runner.fold_resolved: later writes to the same port
  # override earlier ones.
  defp fold_resolved(resolved, channels) do
    Enum.reduce(resolved, %{}, fn {patch, payload}, acc ->
      channels[patch.channel]
      |> target_for(patch)
      |> bind_payload(payload)
      |> Enum.reduce(acc, fn {port_ref, value}, inner ->
        Map.put(inner, port_ref, %{input: value})
      end)
    end)
  end

  defp target_for(module, patch) do
    cond do
      function_exported?(module, :target, 1) ->
        module.target(patch)

      function_exported?(module, :target, 0) ->
        module.target()

      true ->
        raise ArgumentError, "channel #{inspect(module)} exports neither target/0 nor target/1"
    end
  end

  defp bind_payload({:port, _, _} = port_ref, payload), do: [{port_ref, payload}]
  defp bind_payload(fun, payload) when is_function(fun, 1), do: fun.(payload)
end
