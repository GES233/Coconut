defmodule Coconut.Util.ID do
  @moduledoc """
  A module that declares the IDs of domain entities.

  Yes, it's simply identity.
  """

  @typedoc "An identifier for a domain entity."
  @type t :: binary()

  @typedoc "Phantom type tag associating an ID with a specific model."
  @type t(_any_model) :: t()

  @doc """
  Generates the ID of the new object.

  This is a utility function used by the caller (Kernel/adapter layer); Domain's `Model.new/1` does not call it automatically.
  Require the caller to explicitly pass in `:id`.
  """
  @spec generate_id(nil | binary()) :: t()
  def generate_id(id_prefix) do
    (id_prefix || "") <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
