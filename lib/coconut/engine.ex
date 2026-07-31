defmodule Coconut.Engine do
  @moduledoc """
  Provide engine behaviour.
  """

  @type engine :: module() | {module(), config_or_handle :: term()}

  # ---- Callbacks ----

  @callback info(config :: term()) :: %{
              name: String.t(),
              version: String.t()
            }

  # TODO: Update arity to 2
  # check/2

  # render/2

  # ---- API ----

  # run_check

  # run_render
end
