defmodule Coconut.Util.Helpers do
  @moduledoc "Some helpers."

  @doc """
  Normalizes attributes, keeping only keys declared in `fields`.

  Returns `{:ok, normalized_result}` for valid input, which must satisfy:

  - `attrs`: a Map or Keyword list
  - `fields`: a list of atoms or `{key, default}` tuples

  Otherwise returns the corresponding error.

  ### Examples

      iex> Coconut.Util.Helpers.normalize_attrs(
      ...> [name: "初音ミク", platform: {:yamaha, :vocaloid}, extra: "Miku miku~",
      ...> unrelated_context: %{blabla: nil}], [:name, :platform, extra: ""])
      {:ok,
      %{
        extra: "Miku miku~",
        name: "初音ミク",
        platform: {:yamaha, :vocaloid}
      }}

      iex> Coconut.Util.Helpers.normalize_attrs(%{foo: "a"}, 1)
      {:error, {:invalid_fields, 1}}
  """
  @spec normalize_attrs(any(), any()) :: {:ok, map()} | {:error, term()}
  def normalize_attrs(attrs, fields) do
    with {:ok, allowed_set} <- build_allowed_set(fields),
         {:ok, pairs} <- to_pairs(attrs) do
      result =
        for {k, v} <- pairs,
            normalized_key = normalize_key(k),
            not is_nil(normalized_key),
            normalized_key in allowed_set,
            into: %{},
            do: {normalized_key, v}

      {:ok, result}
    end
  end

  @doc """
  Normalize and ensures all attributes keys are declared in `fields`.

  Returns `{:ok, normalized_result}` when every key in `attrs` is allowed;
  otherwise returns `{:error, {:extra_attrs, extra_keys}}`.

  Accepts the same `attrs` and `fields` formats as `normalize_attrs/2`.

  ### Examples

      iex> Coconut.Util.Helpers.strictly_normalize_attrs(
      ...> [name: "初音ミク", platform: {:yamaha, :vocaloid}], [:name, :platform, extra: ""])
      {:ok,
      %{
        name: "初音ミク",
        platform: {:yamaha, :vocaloid}
      }}

      iex> Coconut.Util.Helpers.strictly_normalize_attrs(
      ...> [name: "Miku", unexpected: "x"], [:name])
      {:error, {:extra_attrs, [:unexpected]}}

      iex> Coconut.Util.Helpers.strictly_normalize_attrs(%{foo: "a"}, 1)
      {:error, {:invalid_fields, 1}}
  """
  @spec strictly_normalize_attrs(any(), any()) :: {:ok, map()} | {:error, term()}
  def strictly_normalize_attrs(attrs, fields) do
    with {:ok, allowed_set} <- build_allowed_set(fields),
         {:ok, pairs} <- to_pairs(attrs) do
      {extras, normalized} = Enum.reduce(pairs, {[], %{}}, &add_pair(&1, &2, allowed_set))

      if extras == [] do
        {:ok, normalized}
      else
        {:error, {:extra_attrs, Enum.reverse(extras)}}
      end
    end
  end

  defp add_pair({k, v}, {extras, acc}, allowed_set) do
    normalized_key = normalize_key(k)

    if is_nil(normalized_key) or normalized_key not in allowed_set do
      {[k | extras], acc}
    else
      {extras, Map.put(acc, normalized_key, v)}
    end
  end

  # Builds the set of allowed keys.

  defp build_allowed_set(fields) when is_list(fields) do
    Enum.reduce_while(fields, {:ok, MapSet.new()}, fn
      {k, _default}, {:ok, acc} when is_atom(k) ->
        {:cont, {:ok, MapSet.put(acc, k)}}

      k, {:ok, acc} when is_atom(k) ->
        {:cont, {:ok, MapSet.put(acc, k)}}

      other, _acc ->
        {:halt, {:error, {:invalid_field_spec, other}}}
    end)
  end

  defp build_allowed_set(other), do: {:error, {:invalid_fields, other}}

  # Normalizes attributes into key-value pairs.

  defp to_pairs(attrs) when is_map(attrs), do: {:ok, attrs}

  defp to_pairs(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) or Enum.all?(attrs, &match?({_, _}, &1)) do
      {:ok, attrs}
    else
      {:error, {:invalid_attrs, attrs}}
    end
  end

  defp to_pairs(other), do: {:error, {:invalid_attrs, other}}

  # Normalizes a key to an atom.

  defp normalize_key(k) when is_atom(k), do: k

  defp normalize_key(k) when is_binary(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> nil
  end

  defp normalize_key(_), do: nil
end
