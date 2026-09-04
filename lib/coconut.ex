defmodule Coconut do
  @moduledoc """
  The application facade for editing, interventions, and rendering.

  Lower-level modules remain public for adapters and importers, but host
  applications normally need only this module. A session keeps undo history
  and render configuration together while leaving file parsing, voicebank
  loading, and artifact persistence to the host.

      {:ok, session} =
        Coconut.new(project,
          channels: %{timing: MyTimingChannel},
          engine: {MyEngine, engine_config}
        )

      {:ok, session} = Coconut.edit(session, gesture)
      {:ok, session, _patch} =
        Coconut.mount(session, "vocal", note_id, :timing, %{deltas: deltas})
      {:ok, session, artifact} = Coconut.render(session)

  A session opened from a `Coconut.Project` can be exported with `project/1`.
  History and checked rounds are deliberately session-scoped and are not
  included in that value.
  """

  alias Coconut.Edit.{Command, History, Patch, Track, Workspace}
  alias Coconut.Project
  alias Coconut.Render.{Engine, Resolve}
  alias Coconut.Render.Engine.Request
  alias Coconut.Session
  alias Coconut.Util.ID

  @type source :: Workspace.t() | Project.t()

  @doc """
  Opens a facade session over a workspace or project.

  Options:

  - `:channels` - `%{channel_name => Coconut.Render.Channel module}`;
  - `:engine` - a `Coconut.Render.Engine` module or `{module, config}`;
  - `:interventions` - base engine inputs merged below resolved patches;
  - `:globals` - engine-level values included in every request;
  - `:history` - options forwarded to `Coconut.Edit.History.new/2`, or a
    restored `Coconut.Edit.History` struct (e.g. from
    `Coconut.Pickle.File.read_with_history/2`) mounted as-is — its
    `present.edit_version` must match the workspace's.
  """
  @spec new(source(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def new(source, opts \\ [])

  def new(%Project{} = project, opts) do
    with {:ok, project} <- Project.validate(project),
         {:ok, session} <- build_session(project.workspace, opts) do
      metadata = Map.take(project, [:id, :voicebank, :metadata])
      {:ok, %{session | project: metadata}}
    end
  end

  def new(%Workspace{} = workspace, opts) do
    with {:ok, workspace} <- Workspace.validate(workspace) do
      build_session(workspace, opts)
    end
  end

  def new(other, _opts), do: {:error, {:invalid_source, other}}

  defp build_session(workspace, opts) do
    channels = Keyword.get(opts, :channels, %{})
    interventions = Keyword.get(opts, :interventions, %{})
    globals = Keyword.get(opts, :globals, %{})
    engine = Keyword.get(opts, :engine)

    with :ok <- validate_history_option(Keyword.get(opts, :history, [])),
         :ok <- validate_map_option(:channels, channels),
         :ok <- validate_channels(channels),
         :ok <- validate_engine(engine),
         :ok <- validate_map_option(:interventions, interventions),
         :ok <- validate_map_option(:globals, globals),
         {:ok, history} <- resolve_history(workspace, Keyword.get(opts, :history, [])) do
      {:ok,
       %Session{
         history: history,
         channels: channels,
         engine: engine,
         interventions: interventions,
         globals: globals
       }}
    end
  end

  # 恢复的历史直接挂载：present 是 session workspace 的事实来源
  # （`workspace/1` = `history.present`），这里只做 edit_version 对齐的
  # 健全性检查——存档两侧是同一份会话状态的两次投影，错位即文件损坏。
  defp resolve_history(workspace, %History{} = history) do
    if history.present.edit_version == workspace.edit_version do
      {:ok, history}
    else
      {:error,
       {:history_workspace_mismatch, history.present.edit_version, workspace.edit_version}}
    end
  end

  defp resolve_history(workspace, opts) when is_list(opts),
    do: {:ok, History.new(workspace, opts)}

  @doc "Returns the current workspace."
  @spec workspace(Session.t()) :: Workspace.t()
  def workspace(%Session{history: history}), do: history.present

  @doc "Returns the current history cursor, suitable as a stale-write pin."
  @spec pin(Session.t()) :: History.node_id()
  def pin(%Session{history: history}), do: history.cursor

  @doc "Returns the current workspace and stale-write pin together."
  @spec current(Session.t()) :: %{workspace: Workspace.t(), pin: History.node_id()}
  def current(%Session{} = session), do: %{workspace: workspace(session), pin: pin(session)}

  @doc "Rebuilds the current project for a session opened from a project."
  @spec project(Session.t()) :: {:ok, Project.t()} | {:error, :workspace_session}
  def project(%Session{project: nil}), do: {:error, :workspace_session}

  def project(%Session{project: metadata} = session) do
    Project.new(Map.put(metadata, :workspace, workspace(session)))
  end

  @doc """
  Replaces session-scoped render configuration.

  Accepted keys are `:channels`, `:engine`, `:interventions`, and `:globals`.
  Omitted values are kept. Configuration is not edit history, but changing it
  invalidates the last checked round.
  """
  @spec configure(Session.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def configure(%Session{} = session, opts) when is_list(opts) do
    channels = Keyword.get(opts, :channels, session.channels)
    engine = Keyword.get(opts, :engine, session.engine)
    interventions = Keyword.get(opts, :interventions, session.interventions)
    globals = Keyword.get(opts, :globals, session.globals)

    with :ok <- validate_map_option(:channels, channels),
         :ok <- validate_channels(channels),
         :ok <- validate_engine(engine),
         :ok <- validate_map_option(:interventions, interventions),
         :ok <- validate_map_option(:globals, globals) do
      {:ok,
       %{
         session
         | channels: channels,
           engine: engine,
           interventions: interventions,
           globals: globals,
           last_round: nil
       }}
    end
  end

  def configure(%Session{}, opts), do: {:error, {:invalid_options, opts}}

  @doc "Applies one edit gesture through validation, lowering, history, and optimistic locking."
  @spec edit(Session.t(), Coconut.Edit.Operation.request(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def edit(%Session{} = session, request, opts \\ []) do
    expected_version = Keyword.get(opts, :expected_version, :current)
    history_opts = Keyword.drop(opts, [:expected_version])

    case History.apply(session.history, request, expected_version, history_opts) do
      {:ok, history} -> {:ok, changed(session, history)}
      {:error, _} = error -> error
    end
  end

  @doc "Runs a structural or patch command and records it in history."
  @spec run(Session.t(), Command.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def run(%Session{} = session, %Command{} = command, opts \\ []) do
    case History.run(session.history, command, opts) do
      {:ok, history} -> {:ok, changed(session, history)}
      {:error, _} = error -> error
    end
  end

  @doc "Moves to the preceding live history state."
  @spec undo(Session.t()) :: {:ok, Session.t()} | {:error, :nothing_to_undo}
  def undo(%Session{} = session), do: move(session, &History.undo/1)

  @doc "Moves to the following live history state."
  @spec redo(Session.t()) :: {:ok, Session.t()} | {:error, :nothing_to_redo}
  def redo(%Session{} = session), do: move(session, &History.redo/1)

  defp move(session, fun) do
    case fun.(session.history) do
      {:ok, history} -> {:ok, changed(session, history)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Mounts an ordinal patch using the configured channel's projection.

  `refs` is one element id or a list of ids. The facade captures the track
  version, digests the current projection, creates the Tamale patch, and
  records the attachment in history.

  Options:

  - `:base` — an explicit canonical base term signed instead of the
    channel's workspace projection. Required for `:probe`-stage channels
    (identity/output bases materialize at the engine probe, so the caller
    signs the probe-time value); rejected for `:static` channels, where
    the projection is the only sanctioned base source.
  - `:pin` — forwarded to `Coconut.Edit.History.run/3` (stale-write pin).
  """
  @spec mount(Session.t(), Track.track_id(), term() | [term()], atom(), term(), keyword()) ::
          {:ok, Session.t(), Patch.t()} | {:error, term()}
  def mount(%Session{} = session, track_id, refs, channel, payload, opts \\ []) do
    ws = workspace(session)

    with {:ok, channel_module} <- fetch_channel(session, channel),
         {:ok, track} <- Workspace.fetch_track(ws, track_id),
         anchor <- %Tamale.Anchor.Ordinal{refs: List.wrap(refs), at_version: track.space.version},
         probe <- %Patch{track_id: track_id, anchor: anchor, channel: channel},
         {:ok, base} <- mount_base(channel_module, ws, probe, opts),
         {:ok, tamale_patch} <- Tamale.Patch.new(base, payload),
         {:ok, patch} <-
           Patch.new(%{
             id: ID.generate_id("Patch_"),
             track_id: track_id,
             anchor: anchor,
             channel: channel,
             patch: tamale_patch
           }),
         {:ok, session} <-
           run(session, Command.attach_patches([patch]), Keyword.take(opts, [:pin])) do
      {:ok, session, patch}
    end
  end

  # probe 期 channel 的底料在 workspace 之外物化（引擎 probe），必须由
  # 调用方显式签名；静态 channel 的底料只能来自纯 workspace projection。
  defp mount_base(channel_module, ws, probe, opts) do
    probe_stage? =
      function_exported?(channel_module, :resolve_stage, 0) and
        channel_module.resolve_stage() == :probe

    case {probe_stage?, Keyword.fetch(opts, :base)} do
      {true, :error} -> {:error, {:probe_stage_requires_base, probe.channel}}
      {false, {:ok, base}} -> {:error, {:static_channel_rejects_base, probe.channel, base}}
      {true, {:ok, base}} -> {:ok, base}
      {false, :error} -> channel_module.projection(ws, probe)
    end
  end

  @doc "Moves patches named by resolve entries to the persistent graveyard."
  @spec discard_conflicts(Session.t(), [Resolve.check_entry()], keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def discard_conflicts(%Session{} = session, entries, opts \\ []) when is_list(entries) do
    case entries do
      [] ->
        {:ok, session}

      _entries ->
        with {:ok, discards} <- discard_entries(entries) do
          run(session, Command.discard_patches(discards), opts)
        end
    end
  end

  @doc """
  Moves one or more active patches to the persistent graveyard.

  This is the explicit policy entry for cases such as superseding an older
  patch before mounting its replacement. The discard is recorded in history
  and can be undone.
  """
  @spec discard_patches(Session.t(), Patch.t() | [Patch.t()], term(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def discard_patches(%Session{} = session, patches, reason, opts \\ []) do
    patches = List.wrap(patches)

    case patches do
      [] ->
        {:ok, session}

      patches ->
        with {:ok, discards} <- patch_discards(patches, reason) do
          run(session, Command.discard_patches(discards), opts)
        end
    end
  end

  @doc "Drains apply-time and explicitly discarded patches as a history edge."
  @spec take_dead_patches(Session.t()) :: {[{Patch.t(), term()}], Session.t()}
  def take_dead_patches(%Session{} = session) do
    {dead, history} = History.take_dead_patches(session.history)
    {dead, if(history == session.history, do: session, else: changed(session, history))}
  end

  @doc "Resolves every live patch and merges the results over base interventions."
  @spec resolve(Session.t(), keyword()) ::
          {:ok, %{interventions: map(), survivors: [Patch.t()]}}
          | {:error, {:resolve_vetoed, [Resolve.check_entry()]}}
  def resolve(%Session{} = session, opts \\ []) do
    with {:ok, base} <- merge_option(session.interventions, opts, :interventions) do
      case Resolve.run_check(workspace(session), session.channels) do
        {:ok, %{passed: true} = verdict} ->
          {:ok,
           %{interventions: Map.merge(base, verdict.interventions), survivors: verdict.survivors}}

        {:ok, %{passed: false, entries: entries}} ->
          {:error, {:resolve_vetoed, entries}}
      end
    end
  end

  @doc "Builds an engine request from the current workspace and resolved interventions."
  @spec request(Session.t(), keyword()) :: {:ok, Request.t()} | {:error, term()}
  def request(%Session{} = session, opts \\ []) do
    with {:ok, globals} <- merge_option(session.globals, opts, :globals),
         {:ok, %{interventions: interventions}} <- resolve(session, opts) do
      Request.for_workspace(workspace(session), interventions: interventions, globals: globals)
    end
  end

  @doc "Runs the patch and engine checks, retaining the checked request for rendering."
  @spec check(Session.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def check(%Session{} = session, opts \\ []) do
    with {:ok, engine} <- configured_engine(session),
         {:ok, request} <- request(session, opts),
         {:ok, verdict} <- Engine.run_check(engine, request) do
      case verdict do
        %{passed: true, checked: checked} ->
          {:ok, %{session | last_round: %{request: request, checked: checked}}}

        %{passed: false, entries: entries} ->
          {:error, {:check_vetoed, entries}}
      end
    end
  end

  @doc "Checks the current state and renders it without performing host-side I/O."
  @spec render(Session.t(), keyword()) :: {:ok, Session.t(), term()} | {:error, term()}
  def render(%Session{} = session, opts \\ []) do
    with {:ok, session} <- check(session, opts),
         {:ok, engine} <- configured_engine(session),
         %{request: request, checked: checked} <- session.last_round,
         {:ok, artifact} <- Engine.run_render(engine, request, checked) do
      {:ok, session, artifact}
    end
  end

  @doc "Returns the engine-prepared value from the most recent successful check."
  @spec checked(Session.t()) :: {:ok, term()} | {:error, :not_checked}
  def checked(%Session{last_round: nil}), do: {:error, :not_checked}
  def checked(%Session{last_round: %{checked: checked}}), do: {:ok, checked}

  defp changed(session, history), do: %{session | history: history, last_round: nil}

  defp fetch_channel(%Session{channels: channels}, channel) do
    case Map.fetch(channels, channel) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_channel, channel}}
    end
  end

  defp configured_engine(%Session{engine: nil}), do: {:error, :missing_engine}
  defp configured_engine(%Session{engine: engine}), do: {:ok, engine}

  defp discard_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn
      %{track_id: track_id, patch: %Patch{id: patch_id}} = entry, {:ok, acc}
      when not is_nil(patch_id) ->
        reason = Map.get(entry, :reason, Map.get(entry, :kind))
        {:cont, {:ok, [{track_id, patch_id, reason} | acc]}}

      entry, _acc ->
        {:halt, {:error, {:invalid_conflict_entry, entry}}}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _} = error -> error
    end
  end

  defp patch_discards(patches, reason) do
    Enum.reduce_while(patches, {:ok, []}, fn
      %Patch{id: patch_id, track_id: track_id}, {:ok, acc} when not is_nil(patch_id) ->
        {:cont, {:ok, [{track_id, patch_id, reason} | acc]}}

      patch, _acc ->
        {:halt, {:error, {:invalid_patch_discard, patch}}}
    end)
    |> case do
      {:ok, discards} -> {:ok, Enum.reverse(discards)}
      {:error, _} = error -> error
    end
  end

  # :history 接受 `History.new/2` 的 opts（list）或恢复的历史 struct。
  defp validate_history_option(%History{}), do: :ok
  defp validate_history_option(opts) when is_list(opts), do: :ok
  defp validate_history_option(other), do: {:error, {:invalid_option, :history, other}}

  defp validate_map_option(_name, value) when is_map(value), do: :ok
  defp validate_map_option(name, value), do: {:error, {:invalid_option, name, value}}

  defp validate_channels(channels) do
    case Enum.find(channels, fn {name, module} ->
           not is_atom(name) or not is_atom(module) or
             not Code.ensure_loaded?(module) or
             not function_exported?(module, :projection, 2) or
             (not function_exported?(module, :target, 0) and
                not function_exported?(module, :target, 1))
         end) do
      nil -> :ok
      invalid -> {:error, {:invalid_channel, invalid}}
    end
  end

  defp validate_engine(nil), do: :ok
  defp validate_engine(module) when is_atom(module), do: validate_engine_module(module)

  defp validate_engine({module, _config}) when is_atom(module),
    do: validate_engine_module(module)

  defp validate_engine(engine), do: {:error, {:invalid_engine, engine}}

  defp validate_engine_module(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :info, 1) and
         function_exported?(module, :check, 2) and function_exported?(module, :render, 3) do
      :ok
    else
      {:error, {:invalid_engine, module}}
    end
  end

  defp merge_option(base, opts, name) do
    override = Keyword.get(opts, name, %{})

    case validate_map_option(name, override) do
      :ok -> {:ok, Map.merge(base, override)}
      {:error, _} = error -> error
    end
  end
end
