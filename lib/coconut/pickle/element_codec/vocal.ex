defmodule Coconut.Pickle.ElementCodec.Vocal do
  @moduledoc """
  `Coconut.Edit.Track.Vocal` 的元素 codec（`Coconut.Score.Note`）。

  除 `key` 外字段直出；`key` 的载荷由所属 `Coconut.Score.Key` adapter
  `dump/1` / `load/1` 负责，本 codec 只附加 module 标签。Key 的 Pickle
  表示因此可以和 canonical 表示共享同一套精确性规则；未来微分音 adapter
  可使用整数分数或音律步级，不需要修改本 codec。key 为 nil（如 Rap）
  时原样保留。其余字段经 `Coconut.Score.Note.new/1` 重建（校验生效）。
  """

  @behaviour Coconut.Pickle.ElementCodec

  alias Coconut.Pickle
  alias Coconut.Score.{Key, Note}

  @impl true
  def element_module, do: Note

  @impl true
  def dump_element(%Note{} = note) do
    with {:ok, key} <- dump_key(note.key) do
      {:ok,
       %{
         id: note.id,
         key: key,
         lyric: note.lyric,
         annotation: note.annotation,
         metadata: note.metadata
       }}
    end
  end

  @impl true
  def load_element(%{} = data) do
    with {:ok, key} <- load_key(Map.get(data, :key)) do
      data
      |> Map.put(:key, key)
      |> Note.new()
    end
  end

  defp dump_key(nil), do: {:ok, nil}

  defp dump_key(%module{} = key) do
    with {:ok, dumped} <- Key.dump(key),
         :ok <- validate_key_dump(dumped) do
      {:ok, Map.put(dumped, :module, module)}
    end
  rescue
    _error -> {:error, {:key_dump_failed, key}}
  end

  defp load_key(nil), do: {:ok, nil}

  defp load_key(%{module: module} = dumped) when is_atom(module) do
    dumped
    |> Map.delete(:module)
    |> Key.load(module)
  rescue
    _error -> {:error, {:key_load_failed, dumped}}
  end

  defp load_key(other), do: {:error, {:invalid_key_dump, other}}

  defp validate_key_dump(dumped) when is_map(dumped) do
    cond do
      Map.has_key?(dumped, :module) -> {:error, :reserved_key_dump_field}
      Pickle.pickle_conform?(dumped) -> :ok
      true -> {:error, {:non_conform_key_dump, dumped}}
    end
  end

  defp validate_key_dump(dumped), do: {:error, {:invalid_key_adapter_dump, dumped}}
end
