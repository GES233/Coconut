defmodule Coconut.Render.Engine.Request do
  @moduledoc """
  Input bundle for one engine check/render round.

  Carries the flattened `Coconut.Render.Engine.Snapshot` (never the workspace
  itself, design doc §11.1) plus the folded interventions produced by
  `Coconut.Render.Resolve.run_check/3`. The snapshot pins the workspace's
  `edit_version` — a `checked` bundle is only valid for the version it was
  checked against (design doc §11.5).

  `globals` holds engine-level knobs not anchored to any note (gender,
  depth, quality steps, ...). They bypass the patch/digest/transport axis
  entirely — there is no position to anchor — but they still pass the
  `Coconut.Render.Engine.run_check/2` gate, which validates them against the
  engine's declared `:globals` spec before `check/2` is consulted.
  """

  alias Coconut.Edit.Workspace
  alias Coconut.Render.Engine.Snapshot

  import Coconut.Util.Helpers, only: [normalize_attrs: 2]

  @type t :: %__MODULE__{
          snapshot: Snapshot.t(),
          interventions: %{Coconut.Render.Resolve.port_ref() => %{input: term()}},
          globals: %{atom() => term()}
        }

  @keys [:snapshot, interventions: %{}, globals: %{}]
  defstruct @keys

  @doc "Create a new request from the given attributes."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, normalized} <- normalize_attrs(attrs, @keys) do
      {:ok, struct(__MODULE__, normalized)}
    end
  end

  @doc """
  Build a Request pinned to the workspace's current edit version.

  Options: `:interventions` / `:globals` (as in the struct).
  """
  @spec for_workspace(Workspace.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def for_workspace(%Workspace{} = ws, opts \\ []) do
    with {:ok, snapshot} <- Snapshot.from_workspace(ws) do
      new(%{
        snapshot: snapshot,
        interventions: Keyword.get(opts, :interventions, %{}),
        globals: Keyword.get(opts, :globals, %{})
      })
    end
  end
end
