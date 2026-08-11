defmodule Coconut.Pickle.ElementCodec.Vocal do
  @moduledoc """
  `Coconut.Edit.Track.Vocal` 的元素 codec（`Coconut.Score.Note`）。

  除 `key` 外字段直出；`key` 摊平为 `%{module: key.__struct__, midi: Key.to_midi(key)}`，
  load 时经 `module.from_midi(midi, nil)` 重建（key 为 nil 时原样保留 nil，
  如 Rap 音符）。其余字段经 `Coconut.Score.Note.new/1` 重建（校验生效）。
  """

  @behaviour Coconut.Pickle.ElementCodec

  alias Coconut.Score.{Key, Note}

  @impl true
  def dump_element(%Note{} = note) do
    {:ok,
     %{
       id: note.id,
       key: dump_key(note.key),
       lyric: note.lyric,
       annotation: note.annotation,
       metadata: note.metadata
     }}
  end

  @impl true
  def load_element(%{} = data) do
    with {:ok, key} <- load_key(Map.get(data, :key)) do
      data
      |> Map.put(:key, key)
      |> Note.new()
    end
  end

  defp dump_key(nil), do: nil
  defp dump_key(%module{} = key), do: %{module: module, midi: Key.to_midi(key)}

  defp load_key(nil), do: {:ok, nil}

  # 未知 key module：from_midi 自然报错（或未实现），包装为 error tuple，不 raise
  defp load_key(%{module: module, midi: midi} = dumped)
       when is_atom(module) and is_number(midi) do
    module.from_midi(midi, nil)
  rescue
    _ -> {:error, {:key_from_midi_failed, dumped}}
  end

  defp load_key(other), do: {:error, {:invalid_key_dump, other}}
end
