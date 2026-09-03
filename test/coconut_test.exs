defmodule CoconutTest do
  use ExUnit.Case
  doctest Coconut.Util.Helpers

  alias Coconut.Edit.{Track, Workspace}

  test "workspace construction supplies a usable edit version" do
    assert {:ok, %Workspace{edit_version: 0}} = Workspace.new(%{id: "workspace"})
  end

  test "workspace construction rejects invalid version and tpqn" do
    assert {:error, {:invalid_edit_version, nil}} =
             Workspace.new(%{id: "workspace", edit_version: nil})

    assert {:error, {:invalid_tpqn, 0}} = Workspace.new(%{id: "workspace", tpqn: 0})
  end

  test "workspace construction rejects incomplete track side tables" do
    {:ok, track} =
      Track.new(%{
        id: "vocal",
        module: Track.Vocal,
        space: %Tamale.Space{ids: ["n1"], seen: MapSet.new(["n1"])}
      })

    assert {:error,
            {:track_table_mismatch, %{table: :elements_by_id, missing: ["n1"], extra: []}}} =
             Workspace.new(%{id: "workspace", tracks: %{"vocal" => track}})
  end
end
