defmodule Coconut.Pickle.Track do
  @moduledoc """
  `Coconut.Edit.Track` 的原生对象 codec（arity-2：`dump/2` / `load/2`）。

  不实现 `Coconut.Pickle` behaviour：该 behaviour 只管无上下文 codec，
  需要注入 registry 的 codec 用同风格 arity-2 签名。

  dump 为摊平的 map：

  - `id` 原样直出；
  - `module` 经 `Coconut.Pickle.Registry` 换成逻辑名（load 反向还原）；
  - `space` 走 `Coconut.Pickle.Space` codec；
  - `spans_by_version` 的 version 整数键直出（约定允许的 map 键类型），
    span `{start, end}` → 二元 list `[start, end]`，端点按
    `Coconut.Edit.Track.span()` 约定为整数直出；
  - `elements_by_id` 按能力委托：track module 具备 `:element_codec`
    能力（`dump_element/1` + `load_element/1` 成对导出，统一经
    `Coconut.Edit.Track.supports?/2` 探测）则逐元素委托；不具备且元素表
    为空则放行，不具备且非空报 `{:error, {:no_element_codec, module}}`；
  - `patches` 走 `Coconut.Pickle.Patch` codec；
  - `dead_patches` 的 `{patch, reason}` → `[patch_dump, reason]`，reason
    原样透传但须满足 `Coconut.Pickle` 允许类型约定，否则
    `{:error, {:non_conform_dead_reason, reason}}`。

  load 反向还原后经 `Coconut.Edit.Track.new/1` 重建。

  ## registry

  `default_registry/0` 只注册椰子自带的两种轨型。宿主应用应自建
  registry（可在 `default_registry/0` 基础上 `Registry.register/3` 扩展），
  并在存取档时显式传入——registry 是存档格式的一部分，不是全局状态。
  """

  alias Coconut.Pickle.{Patch, Registry, Space}
  alias Coconut.Edit.Track
  import Coconut.Pickle

  @doc "自带轨型的默认 registry：`\"vocal\"` / `\"tempo\"`。"
  @spec default_registry() :: Registry.t()
  def default_registry do
    {:ok, registry} =
      Registry.new(%{"vocal" => Coconut.Edit.Track.Vocal, "tempo" => Coconut.Edit.Track.Tempo})

    registry
  end

  @doc "把 `Coconut.Edit.Track` 摊平为仅含允许类型的 plain map。"
  @spec dump(Track.t(), Registry.t()) :: {:ok, map()} | {:error, term()}
  def dump(%Track{} = track, %Registry{} = registry) do
    with {:ok, name} <- Registry.to_name(registry, track.module),
         {:ok, space} <- Space.dump(track.space),
         {:ok, elements} <- dump_elements(track),
         {:ok, patches} <- dump_patches(track.patches),
         {:ok, dead} <- dump_dead(track.dead_patches) do
      {:ok,
       %{
         id: track.id,
         module: name,
         space: space,
         spans_by_version: dump_spans(track.spans_by_version),
         elements_by_id: elements,
         patches: patches,
         dead_patches: dead
       }}
    end
  end

  def dump(other, %Registry{}), do: {:error, {:invalid_track, other}}

  @doc "从 plain map 重建 `Coconut.Edit.Track`（经 `Track.new/1`）。"
  @spec load(map(), Registry.t()) :: {:ok, Track.t()} | {:error, term()}
  def load(%{} = data, %Registry{} = registry) do
    with {:ok, module} <- load_module(Map.get(data, :module), registry),
         {:ok, space} <- load_space(Map.get(data, :space)),
         {:ok, spans} <- load_spans(Map.get(data, :spans_by_version)),
         {:ok, elements} <- load_elements(module, Map.get(data, :elements_by_id)),
         {:ok, patches} <- load_patches(Map.get(data, :patches)),
         {:ok, dead} <- load_dead(Map.get(data, :dead_patches)) do
      Track.new(%{
        id: Map.get(data, :id),
        module: module,
        space: space,
        spans_by_version: spans,
        elements_by_id: elements,
        patches: patches,
        dead_patches: dead
      })
    end
  end

  def load(other, %Registry{}), do: {:error, {:invalid_track_dump, other}}

  # ---- module 标签 ----

  defp load_module(name, registry) when is_binary(name), do: Registry.to_module(registry, name)

  defp load_module(other, _registry), do: {:error, {:invalid_module_name_dump, other}}

  # ---- space ----

  defp load_space(%{} = dumped), do: Space.load(dumped)
  defp load_space(other), do: {:error, {:invalid_space_dump, other}}

  # ---- spans_by_version ----

  defp dump_spans(spans_by_version) do
    Map.new(spans_by_version, fn {version, spans} ->
      {version, Map.new(spans, fn {id, {start, stop}} -> {id, [start, stop]} end)}
    end)
  end

  defp load_spans(spans_by_version) when is_map(spans_by_version) do
    Enum.reduce_while(spans_by_version, {:ok, %{}}, fn {version, spans}, {:ok, acc} ->
      case load_span_table(version, spans) do
        {:ok, table} -> {:cont, {:ok, Map.put(acc, version, table)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp load_spans(other), do: {:error, {:invalid_spans_dump, other}}

  defp load_span_table(version, spans) when is_integer(version) and is_map(spans) do
    Enum.reduce_while(spans, {:ok, %{}}, fn {id, span}, {:ok, acc} ->
      case span do
        [start, stop] -> {:cont, {:ok, Map.put(acc, id, {start, stop})}}
        other -> {:halt, {:error, {:invalid_span_dump, other}}}
      end
    end)
  end

  defp load_span_table(version, spans),
    do: {:error, {:invalid_span_table_dump, {version, spans}}}

  # ---- elements（按能力委托） ----

  defp dump_elements(%Track{module: module, elements_by_id: elements}) do
    cond do
      map_size(elements) == 0 ->
        {:ok, %{}}

      Track.supports?(module, :element_codec) ->
        Enum.reduce_while(elements, {:ok, %{}}, fn {id, element}, {:ok, acc} ->
          case module.dump_element(element) do
            {:ok, dumped} -> {:cont, {:ok, Map.put(acc, id, dumped)}}
            {:error, _} = err -> {:halt, err}
          end
        end)

      true ->
        {:error, {:no_element_codec, module}}
    end
  end

  defp load_elements(module, elements) when is_map(elements) do
    cond do
      map_size(elements) == 0 ->
        {:ok, %{}}

      Track.supports?(module, :element_codec) ->
        Enum.reduce_while(elements, {:ok, %{}}, fn {id, dumped}, {:ok, acc} ->
          case module.load_element(dumped) do
            {:ok, element} -> {:cont, {:ok, Map.put(acc, id, element)}}
            {:error, _} = err -> {:halt, err}
          end
        end)

      true ->
        {:error, {:no_element_codec, module}}
    end
  end

  defp load_elements(_module, other), do: {:error, {:invalid_elements_dump, other}}

  # ---- patches / dead_patches ----

  defp dump_patches(patches) when is_list(patches) do
    Enum.reduce_while(patches, {:ok, []}, fn patch, {:ok, acc} ->
      case Patch.dump(patch) do
        {:ok, dumped} -> {:cont, {:ok, [dumped | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> reverse_result()
  end

  defp load_patches(patches) when is_list(patches) do
    Enum.reduce_while(patches, {:ok, []}, fn dumped, {:ok, acc} ->
      case Patch.load(dumped) do
        {:ok, patch} -> {:cont, {:ok, [patch | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> reverse_result()
  end

  defp load_patches(other), do: {:error, {:invalid_patches_dump, other}}

  defp dump_dead(dead) when is_list(dead) do
    Enum.reduce_while(dead, {:ok, []}, fn {patch, reason}, {:ok, acc} ->
      with {:ok, dumped} <- Patch.dump(patch),
           :ok <- check_conform_reason(reason) do
        {:cont, {:ok, [[dumped, reason] | acc]}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> reverse_result()
  end

  defp load_dead(dead) when is_list(dead) do
    Enum.reduce_while(dead, {:ok, []}, fn entry, {:ok, acc} ->
      with [dumped, reason] <- entry,
           {:ok, patch} <- Patch.load(dumped),
           :ok <- check_conform_reason(reason) do
        {:cont, {:ok, [{patch, reason} | acc]}}
      else
        {:error, _} = err -> {:halt, err}
        other -> {:halt, {:error, {:invalid_dead_patch_dump, other}}}
      end
    end)
    |> reverse_result()
  end

  defp load_dead(other), do: {:error, {:invalid_dead_patches_dump, other}}

  # dead reason 原样透传，但 dump 产物必须满足 Coconut.Pickle 的允许类型约定
  defp check_conform_reason(reason) do
    if pickle_conform?(reason), do: :ok, else: {:error, {:non_conform_dead_reason, reason}}
  end

  defp reverse_result({:ok, acc}), do: {:ok, Enum.reverse(acc)}
  defp reverse_result(err), do: err
end
