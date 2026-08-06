defmodule Coconut.Pickle.RegistryTest do
  use ExUnit.Case, async: true

  alias Coconut.Pickle.Registry

  describe "new/1" do
    test "empty map builds an empty registry" do
      assert {:ok, %Registry{by_name: by_name, by_module: by_module}} = Registry.new(%{})
      assert by_name == %{}
      assert by_module == %{}
    end

    test "builds both directions from a mapping" do
      assert {:ok, registry} = Registry.new(%{"vocal" => Coconut.Edit.Track.Vocal})
      assert Registry.to_name(registry, Coconut.Edit.Track.Vocal) == {:ok, "vocal"}
      assert Registry.to_module(registry, "vocal") == {:ok, Coconut.Edit.Track.Vocal}
    end

    test "duplicate module in the initial mapping is an error" do
      assert {:error, {:module_taken, Coconut.Edit.Track.Vocal}} =
               Registry.new(%{
                 "vocal" => Coconut.Edit.Track.Vocal,
                 "v2" => Coconut.Edit.Track.Vocal
               })
    end
  end

  describe "register/3" do
    test "registers a new pair, returning a new registry" do
      {:ok, registry} = Registry.new(%{})
      assert {:ok, registry} = Registry.register(registry, "tempo", Coconut.Edit.Track.Tempo)
      assert Registry.to_module(registry, "tempo") == {:ok, Coconut.Edit.Track.Tempo}
    end

    test "name conflict is an error" do
      {:ok, registry} = Registry.new(%{"vocal" => Coconut.Edit.Track.Vocal})

      assert {:error, {:name_taken, "vocal"}} =
               Registry.register(registry, "vocal", Coconut.Edit.Track.Tempo)
    end

    test "module conflict (alias) is an error" do
      {:ok, registry} = Registry.new(%{"vocal" => Coconut.Edit.Track.Vocal})

      assert {:error, {:module_taken, Coconut.Edit.Track.Vocal}} =
               Registry.register(registry, "singing", Coconut.Edit.Track.Vocal)
    end
  end

  describe "lookup errors" do
    test "unregistered module reports {:unregistered_module, _}" do
      {:ok, registry} = Registry.new(%{})
      assert {:error, {:unregistered_module, String}} = Registry.to_name(registry, String)
    end

    test "unknown name reports {:unknown_type_name, _}" do
      {:ok, registry} = Registry.new(%{})
      assert {:error, {:unknown_type_name, "nope"}} = Registry.to_module(registry, "nope")
    end
  end
end
