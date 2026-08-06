defmodule Coconut.Render.Engine do
  @moduledoc """
  Engine behaviour and dispatch.

  An engine is a module implementing this behaviour, or a `{module, config}`
  tuple carrying a config/handle. The two-stage contract:

  - `check/2` — the engine's own gate over a `Request`. Always consulted
    before `render/2`; a failure here aborts the round. (Patch-level
    conflicts are vetoed earlier, in `Coconut.Render.Resolve.run_check/3`.) On
    success it returns `{:ok, checked}` — whatever the engine prepared
    (projections, probes, pre-computed forwards) — which is handed back
    to `render/3` so work done at check time is not redone at render time.
  - `render/3` — produce an artifact from the same `Request` plus the
    `checked` term from `check/2`.

  ## Capability declaration

  `info/1` doubles as the engine's capability declaration. The optional
  `:globals` key names the engine-level knobs the engine accepts, each with
  a spec: `{:range, min, max}` for numbers or `{:enum, [term]}` for a fixed
  set. `run_check/2` validates `Request.globals` against this declaration
  before `check/2` — unknown or out-of-spec knobs yield a veto verdict
  (`passed: false`), same one-vote semantics as patch conflicts. Engines
  that declare no `:globals` accept none.

  ## Verdict semantics

  `{:ok, verdict}` means the check **executed**; the verdict is data:
  `passed: true` proceeds to render (carrying `checked`), `passed: false`
  vetoes the round (carrying the aggregated `entries`). `{:error, _}` is
  reserved for checks that could not execute at all (crashed worker,
  missing config, unassemblable input).
  """

  alias Coconut.Render.Engine.Request

  @type engine :: module() | {module(), config_or_handle :: term()}

  @typedoc "Spec for one engine-level knob: a numeric range or a fixed set."
  @type global_spec :: {:range, number(), number()} | {:enum, [term()]}

  @typedoc "A globals-gate failure. Entries are aggregated before vetoing."
  @type global_entry :: %{kind: :global, key: atom(), reason: term()}

  @typedoc """
  Verdict of an executed check.

  `passed: false` vetoes the round — the caller must not proceed to
  render — but the check itself executed fine. `checked` is the engine's
  prepared state handed back to `render/3` (nil on a veto).
  """
  @type check_verdict :: %{
          passed: boolean(),
          entries: [term()],
          checked: term()
        }

  # ---- Callbacks ----

  @callback info(config :: term()) :: %{
              optional(:globals) => %{atom() => global_spec()},
              name: String.t(),
              info: String.t(),
              version: String.t()
            }

  @callback check(Request.t(), config :: term()) :: {:ok, check_verdict()} | {:error, term()}

  @callback render(Request.t(), checked :: term(), config :: term()) ::
              {:ok, term()} | {:error, term()}

  # ---- API ----

  @spec run_check(engine(), Request.t()) :: {:ok, check_verdict()} | {:error, term()}
  def run_check(engine, %Request{} = request) do
    {module, config} = unpack(engine)

    case validate_globals(request.globals, module.info(config)) do
      [] -> module.check(request, config)
      entries -> {:ok, %{passed: false, entries: entries, checked: nil}}
    end
  end

  @spec run_render(engine(), Request.t(), checked :: term()) :: {:ok, term()} | {:error, term()}
  def run_render(engine, %Request{} = request, checked) do
    {module, config} = unpack(engine)
    module.render(request, checked, config)
  end

  # ---- Globals gate ----

  defp validate_globals(globals, info) do
    declared = Map.get(info, :globals, %{})

    for {key, value} <- globals,
        entry = check_global(key, value, declared),
        do: entry
  end

  defp check_global(key, value, declared) do
    case Map.fetch(declared, key) do
      :error ->
        %{kind: :global, key: key, reason: :unknown_global}

      {:ok, spec} ->
        case conform(spec, value) do
          :ok -> nil
          {:error, reason} -> %{kind: :global, key: key, reason: reason}
        end
    end
  end

  defp conform({:range, lo, hi}, value) when is_number(value) do
    if value >= lo and value <= hi, do: :ok, else: {:error, {:out_of_range, {lo, hi}}}
  end

  defp conform({:range, _, _}, _value), do: {:error, :not_a_number}

  defp conform({:enum, allowed}, value) do
    if value in allowed, do: :ok, else: {:error, {:not_in_enum, allowed}}
  end

  defp unpack({module, config}) when is_atom(module), do: {module, config}
  defp unpack(module) when is_atom(module), do: {module, nil}
end
