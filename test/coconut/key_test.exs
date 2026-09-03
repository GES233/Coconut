defmodule Coconut.KeyTest do
  use ExUnit.Case, async: true

  defmodule ExactMicrotone do
    use Coconut.Score.Key

    defstruct [:step, :division]

    @impl true
    def new(%{step: step, division: division})
        when is_integer(step) and is_integer(division) and division > 0 do
      {:ok, %__MODULE__{step: step, division: division}}
    end

    def new(attrs), do: {:error, {:invalid_microtone, attrs}}

    @impl true
    def to_canonical(%__MODULE__{step: step, division: division}) do
      %{step: step, division: division}
    end

    @impl true
    def dump(%__MODULE__{} = key), do: {:ok, to_canonical(key)}

    @impl true
    def load(%{step: step, division: division} = data) when map_size(data) == 2 do
      new(%{step: step, division: division})
    end

    def load(data), do: {:error, {:invalid_microtone_dump, data}}
  end

  alias Coconut.Pickle.ElementCodec.Vocal
  alias Coconut.Score.{Key, Note}

  describe "TwelveET 精确边界" do
    test "整数 canonical 兼容既有 digest 形状" do
      assert {:ok, key} = Key.new(60, Key.TwelveET)
      assert Key.to_canonical(key) === %{midi: 60}
      assert {:ok, %{midi: 60}} = Key.dump(key)
    end

    test "整数值 float 在构造和旧档加载时归一为 integer" do
      assert {:ok, key} = Key.from_midi(60.0, nil, Key.TwelveET)
      assert key.midi === 60

      assert {:ok, loaded} = Key.load(%{midi: 60.0}, Key.TwelveET)
      assert loaded.midi === 60
    end

    test "小数 MIDI 通过十进制字符串进入 canonical 和 Pickle" do
      assert {:ok, key} = Key.new(60.5, Key.TwelveET)
      assert Key.to_canonical(key) === %{midi: "60.5"}
      assert {:ok, %{midi: "60.5"} = dumped} = Key.dump(key)
      assert {:ok, ^key} = Key.load(dumped, Key.TwelveET)

      assert {:ok, note} = Note.new(%{id: "n1", key: key, lyric: "la"})
      assert {:ok, _patch} = Tamale.Patch.new(Note.to_canonical(note), :payload)
    end
  end

  test "精确微分音 adapter 无需修改 Note 或 Vocal Pickle" do
    assert {:ok, key} = Key.new(%{step: 181, division: 3}, ExactMicrotone)
    assert {:ok, note} = Note.new(%{id: "n1", key: key, lyric: "la"})

    assert Note.to_canonical(note).key === %{step: 181, division: 3}
    assert {:ok, _patch} = Tamale.Patch.new(Note.to_canonical(note), :payload)

    assert {:ok, dumped} = Vocal.dump_element(note)

    assert dumped.key === %{
             module: ExactMicrotone,
             step: 181,
             division: 3
           }

    assert {:ok, loaded} = Vocal.load_element(dumped)
    assert loaded === note
  end
end
