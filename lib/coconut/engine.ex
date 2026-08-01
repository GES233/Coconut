defmodule Coconut.Engine do
  @moduledoc """
  Engine behaviour and dispatch.

  An engine is a module implementing this behaviour, or a `{module, config}`
  tuple carrying a config/handle. The two-stage contract:

  - `check/2` — the engine's own gate over a `Request`. Always consulted
    before `render/2`; a failure here aborts the round. (Patch-level
    conflicts are vetoed earlier, in `Coconut.Resolve.run_check/3`.)
  - `render/2` — produce an artifact from the same `Request`.
  """

  alias Coconut.Engine.Request

  @type engine :: module() | {module(), config_or_handle :: term()}

  # ---- Callbacks ----

  @callback info(config :: term()) :: %{
              name: String.t(),
              version: String.t()
            }

  @callback check(Request.t(), config :: term()) :: :ok | {:error, term()}

  @callback render(Request.t(), config :: term()) :: {:ok, term()} | {:error, term()}

  # ---- API ----

  @spec run_check(engine(), Request.t()) :: :ok | {:error, term()}
  def run_check(engine, %Request{} = request) do
    {module, config} = unpack(engine)
    module.check(request, config)
  end

  @spec run_render(engine(), Request.t()) :: {:ok, term()} | {:error, term()}
  def run_render(engine, %Request{} = request) do
    {module, config} = unpack(engine)
    module.render(request, config)
  end

  defp unpack({module, config}) when is_atom(module), do: {module, config}
  defp unpack(module) when is_atom(module), do: {module, nil}
end
