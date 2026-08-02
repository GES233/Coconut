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
  the whole batch: `{:error, {:check_failed, [entry]}}`. On success the
  resolved payloads are folded into `%{port_ref => %{input: value}}` engine
  interventions via each channel's `target`.

  Channel specs are caller-supplied: digest projection shapes are domain
  policy, not kernel policy.
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
  @type channel_spec :: %{
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

  Returns `{:ok, %{interventions: ..., survivors: ...}}` when all patches
  survive transport and resolve cleanly; `{:error, {:check_failed, entries}}`
  otherwise. `survivors` carry transported (up-to-date) anchors.
  """
  @spec run_check(Workspace.t(), %{atom() => channel_spec()}, keyword()) ::
          {:ok, %{interventions: %{port_ref() => %{input: term()}}, survivors: [Patch.t()]}}
          | {:error, {:check_failed, [check_entry()]}}
  def run_check(ws, channels, opts \\ [])

  def run_check(%Workspace{} = ws, channels, _opts) when is_map(channels) do
    {survivors, transport_entries} = transport_all(ws)
    {resolved, resolve_entries} = resolve_all(ws, survivors, channels)

    case transport_entries ++ resolve_entries do
      [] ->
        {:ok, %{interventions: fold_resolved(resolved, channels), survivors: survivors}}

      entries ->
        {:error, {:check_failed, entries}}
    end
  end

  # ---- Transport stage ----

  defp transport_all(ws) do
    track_ids = ws.side.patches |> Enum.map(& &1.track_id) |> Enum.uniq()

    Enum.reduce(track_ids, {[], []}, fn track_id, {surv_acc, entry_acc} ->
      if known_track?(ws, track_id) do
        track_patches = Enum.filter(ws.side.patches, &(&1.track_id == track_id))
        warp_provider = WarpProvider.tick(Workspace.track_spans(ws, track_id), track_patches)
        {:ok, survivors, dead} = Workspace.transport_patches(ws, track_id, warp_provider)

        # transport_patches returns the full patch list with only this
        # track's patches transported; keep just this track's results.
        own = Enum.filter(survivors, &(&1.track_id == track_id))
        entries = Enum.map(dead, &transport_entry(elem(&1, 0), elem(&1, 1)))

        {surv_acc ++ own, entry_acc ++ entries}
      else
        entries =
          ws.side.patches
          |> Enum.filter(&(&1.track_id == track_id))
          |> Enum.map(&transport_entry(&1, {:unknown_track, track_id}))

        {surv_acc, entry_acc ++ entries}
      end
    end)
  end

  defp known_track?(ws, :tempo), do: not is_nil(ws.tempo_space)
  defp known_track?(ws, track_id), do: Map.has_key?(ws.tracks, track_id)

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
          case resolve_one(ws, patch, spec) do
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

  # Mirrors equinox Runner.fold_resolved: later writes to the same port
  # override earlier ones.
  defp fold_resolved(resolved, channels) do
    Enum.reduce(resolved, %{}, fn {patch, payload}, acc ->
      channels[patch.channel].target
      |> bind_payload(payload)
      |> Enum.reduce(acc, fn {port_ref, value}, inner ->
        Map.put(inner, port_ref, %{input: value})
      end)
    end)
  end

  defp bind_payload({:port, _, _} = port_ref, payload), do: [{port_ref, payload}]
  defp bind_payload(fun, payload) when is_function(fun, 1), do: fun.(payload)
end
