defmodule Coconut.Pickle.Patch do
  @moduledoc """
  `Coconut.Patch` 的原生对象 codec。

  dump 为摊平的 map，五个字段：

  - `id` / `track_id` / `channel` 原样直出；
  - `anchor` 走 `Coconut.Pickle.Anchor` codec（嵌套带 `module` 标签的 map）；
  - `patch`（`Tamale.Patch`）摊平为
    `%{module: Tamale.Patch, base_digest: ..., payload: ...}`：
    `base_digest` 是 binary 直出，`payload` 按 `Coconut.Pickle` 契约原样透传，
    不做深度规整。

  load 时 anchor 经 `Coconut.Pickle.Anchor.load/1` 重建；`Tamale.Patch`
  只有 `new/2`（吃 base 原文现算 digest），无法从 `base_digest` 反演，
  故直接 `struct/2` 重建；最后整体经 `Coconut.Patch.new/1` 重建
  （coord 支持性校验生效）。非法输入返回 error tuple，不 raise。
  """

  @behaviour Coconut.Pickle

  alias Coconut.Patch
  alias Coconut.Pickle.Anchor, as: PickleAnchor

  @impl true
  def dump(%Patch{} = patch) do
    with {:ok, anchor} <- PickleAnchor.dump(patch.anchor) do
      {:ok,
       %{
         id: patch.id,
         track_id: patch.track_id,
         anchor: anchor,
         patch: dump_tamale_patch(patch.patch),
         channel: patch.channel
       }}
    end
  end

  def dump(other), do: {:error, {:invalid_patch, other}}

  @impl true
  def load(%{} = data) do
    with {:ok, anchor} <- load_anchor(Map.get(data, :anchor)),
         {:ok, tamale_patch} <- load_tamale_patch(Map.get(data, :patch)) do
      data
      |> Map.put(:anchor, anchor)
      |> Map.put(:patch, tamale_patch)
      |> Patch.new()
    end
  end

  def load(other), do: {:error, {:invalid_patch_dump, other}}

  defp dump_tamale_patch(%Tamale.Patch{} = patch) do
    %{module: Tamale.Patch, base_digest: patch.base_digest, payload: patch.payload}
  end

  defp load_anchor(%{} = dumped), do: PickleAnchor.load(dumped)
  defp load_anchor(other), do: {:error, {:invalid_anchor_dump, other}}

  defp load_tamale_patch(%{module: Tamale.Patch, base_digest: digest, payload: payload})
       when is_binary(digest) do
    {:ok, %Tamale.Patch{base_digest: digest, payload: payload}}
  end

  defp load_tamale_patch(other), do: {:error, {:invalid_tamale_patch_dump, other}}
end
