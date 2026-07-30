defmodule Coconut.Util.Model do
  @moduledoc """
  Domain model helper.

  Invoking `use Coconut.Util.Model, keys: [...], id_prefix: "xxx"` generates:

  - struct definition
  - `new/1` — generated; the caller must still provide `:id` explicitly
  - `validate/1`
  - `update/2`

  ## ID Generation

  `new/1` no longer generates an ID automatically. The caller generates the ID using `Coconut.Util.ID.generate_id/1` and passes it in.
  It ensures the Domain layer does not rely on random numbers.

  ## Writing business functions (recommended)

  Return `{:ok, result}` or `{:error, reason}`.
  """

  @doc "Check if the domain model is valid."
  @callback validate(model :: struct()) :: {:ok, struct()} | {:error, term()}
  @optional_callbacks [validate: 1]

  defmacro __using__(opts) do
    # If a development-time error occurs, raise it immediately.
    keys = Keyword.fetch!(opts, :keys)
    id_prefix = Keyword.get(opts, :id_prefix)

    quote do
      import Coconut.Helpers, only: [normalize_attrs: 2, strictly_normalize_attrs: 2]

      @behaviour Coconut.Util.Model

      @keys unquote(keys)
      defstruct @keys

      @doc "Create a new struct based on the attributes. `:id` must be provided explicitly."
      def new(attrs) do
        with {:ok, normalized} <- normalize_attrs(attrs, @keys) do
          case Map.fetch(normalized, :id) do
            :error ->
              {:error, {:missing_id, unquote(id_prefix)}}

            {:ok, id} ->
              struct(__MODULE__, Map.put(normalized, :id, id))
              |> validate()
          end
        end
      end

      @doc "Modify the properties of an existing struct (modifying the id is not allowed)."
      def update(model, attrs) do
        with {:ok, normalized} <- strictly_normalize_attrs(attrs, @keys),
             :ok <- if(Map.has_key?(normalized, :id), do: {:error, :id_immutable}, else: :ok),
             new_model = struct(model, normalized) do
          validate(new_model)
        end
      end

      @impl true
      def validate(model), do: {:ok, model}
      defoverridable new: 1, update: 2, validate: 1
    end
  end
end
