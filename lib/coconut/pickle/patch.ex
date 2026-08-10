defmodule Coconut.Pickle.Patch do
  @moduledoc """
  `Coconut.Edit.Patch` 的原生对象 codec。

  dump 为摊平的 map，五个字段：

  - `id` / `track_id` / `channel` 原样直出；
  - `anchor` 走 `Coconut.Pickle.Anchor` codec（嵌套带 `module` 标签的 map）；
  - `patch`（`Tamale.Patch`）摊平为
    `%{module: Tamale.Patch, base_digest: ..., payload: ...}`：
    `base_digest` 是 binary 直出，`payload` 按 `Coconut.Pickle` 契约原样透传，
    不做深度规整。

  字段规格驱动（`Coconut.Pickle.Struct`）。load 时 `Tamale.Patch` 只有
  `new/2`（吃 base 原文现算 digest），无法从 `base_digest` 反演，故直接
  `struct/2` 重建；最后整体经 `Coconut.Edit.Patch.new/1` 重建（coord
  支持性校验生效）。非法输入返回 error tuple，不 raise。
  """

  @behaviour Coconut.Pickle

  alias Coconut.Edit.Patch
  alias Coconut.Pickle.{Anchor, Struct}

  @impl true
  def dump(patch), do: Struct.dump(Patch, patch, fields())

  @impl true
  def load(data), do: Struct.load(Patch, data, fields())

  # fun 捕获无法注入模块属性（Macro.escape 不支持 fun），规格由函数返回
  defp fields do
    [
      :id,
      :track_id,
      :channel,
      {:anchor, {:codec, Anchor}},
      {:patch, {&dump_tamale_patch/1, &load_tamale_patch/1}}
    ]
  end

  defp dump_tamale_patch(%Tamale.Patch{} = patch) do
    {:ok, %{module: Tamale.Patch, base_digest: patch.base_digest, payload: patch.payload}}
  end

  defp load_tamale_patch(%{module: Tamale.Patch, base_digest: digest, payload: payload})
       when is_binary(digest) do
    {:ok, %Tamale.Patch{base_digest: digest, payload: payload}}
  end

  defp load_tamale_patch(other), do: {:error, {:invalid_tamale_patch_dump, other}}
end
