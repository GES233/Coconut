defmodule Coconut.Resolve do
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

  Channel specs are caller-supplied: digest projection shapes are domain
  policy, not kernel policy. A spec is either a module implementing the
  `Coconut.Channel` behaviour or an ad-hoc `%{projection, target}` map.
  """

  alias Coconut.{Patch, WarpProvider, Workspace}

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
  @type channel_spec ::
          module()
          | %{
              projection: (Workspace.t(), Patch.t() -> {:ok, term()} | {:error, term()}),
              target: port_ref() | (term() -> [{port_ref(), term()}])
            }

  @typedoc "A single check failure. Entries are aggregated before vetoing."
  @type check_entry :: %{
          :kind => :conflict | :transport | :unknown_channel | :projection_failed,
          :track_id => Coconut.Operate.track_id(),
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
  # track's patch list (tempo field included, via `Workspace.all_tracks/1`);
  # an out-of-band mount on an unknown track is rejected at
  # `Workspace.attach_patch/2` and cannot occur here.
  defp transport_all(ws) do
    Enum.reduce(Workspace.all_tracks(ws), {[], []}, fn {track_id, track}, {surv_acc, entry_acc} ->
      case track.patches do
        [] ->
          {surv_acc, entry_acc}

        patches ->
          warp_provider = WarpProvider.tick(Coconut.Track.spans(track), patches)
          {:ok, survivors, dead} = Workspace.transport_patches(ws, track_id, warp_provider)
          entries = Enum.map(dead, &transport_entry(elem(&1, 0), elem(&1, 1)))

          {surv_acc ++ survivors, entry_acc ++ entries}
      end
    end)
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
    Enum.reduce(survivors, {[], []}, fn patch, {ok_acc, entry_acc} ->
      case Map.fetch(channels, patch.channel) do
        :error ->
          entry = %{
            kind: :unknown_channel,
            track_id: patch.track_id,
            patch: patch,
            channel: patch.channel
          }

          {ok_acc, entry_acc ++ [entry]}

        {:ok, spec} ->
          case resolve_one(ws, patch, normalize_spec(spec)) do
            {:ok, payload} -> {ok_acc ++ [{patch, payload}], entry_acc}
            {:error, entry} -> {ok_acc, entry_acc ++ [entry]}
          end
      end
    end)
  end

  defp resolve_one(ws, %Patch{} = patch, spec) do
    with {:ok, fresh_base} <- spec.projection.(ws, patch),
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
    end
  end

  # ---- Fold ----

  # A channel spec is either an ad-hoc map or a `Coconut.Channel` module.
  defp normalize_spec(%{projection: _, target: _} = spec), do: spec

  defp normalize_spec(module) when is_atom(module) do
    Code.ensure_loaded!(module)
    base = %{projection: &module.projection/2}

    cond do
      function_exported?(module, :target, 1) ->
        Map.put(base, :patch_target, &module.target/1)

      function_exported?(module, :target, 0) ->
        Map.put(base, :target, module.target())

      true ->
        raise ArgumentError, "channel #{inspect(module)} exports neither target/0 nor target/1"
    end
  end

  # Mirrors equinox Runner.fold_resolved: later writes to the same port
  # override earlier ones.
  defp fold_resolved(resolved, channels) do
    Enum.reduce(resolved, %{}, fn {patch, payload}, acc ->
      channels[patch.channel]
      |> normalize_spec()
      |> target_for(patch)
      |> bind_payload(payload)
      |> Enum.reduce(acc, fn {port_ref, value}, inner ->
        Map.put(inner, port_ref, %{input: value})
      end)
    end)
  end

  defp target_for(%{patch_target: fun}, patch), do: fun.(patch)
  defp target_for(%{target: target}, _patch), do: target

  defp bind_payload({:port, _, _} = port_ref, payload), do: [{port_ref, payload}]
  defp bind_payload(fun, payload) when is_function(fun, 1), do: fun.(payload)
end
