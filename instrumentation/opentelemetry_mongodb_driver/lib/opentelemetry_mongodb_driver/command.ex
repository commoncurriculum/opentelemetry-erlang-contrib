defmodule OpentelemetryMongodbDriver.Command do
  @moduledoc false

  def sanitize([{command_name, _} | _] = command, obfuscate) do
    %{}
    |> maybe_put(command, :key)
    |> maybe_put(command, :query, &sanitize_map(&1, obfuscate))
    |> maybe_put(command, :filter, &sanitize_map(&1, obfuscate))
    |> maybe_put(command, :sort)
    |> maybe_put(command, :new)
    |> maybe_put(command, :update, &sanitize_find_and_modify(command_name, &1, obfuscate))
    |> maybe_put(command, :remove)
    |> maybe_put(command, :updates, &sanitize_updates(&1, obfuscate))
    |> maybe_put(command, :deletes, &sanitize_deletes(&1, obfuscate))
    |> maybe_put(command, :pipeline, &sanitize_pipeline(&1, obfuscate))
    |> maybe_serialize()
  end

  defp sanitize_find_and_modify(:findAndModify, map, obfuscate), do: sanitize_map(map, obfuscate)
  defp sanitize_find_and_modify(_other, _update, _obfuscate), do: nil

  defp sanitize_updates([update | rest] = _updates, obfuscate) do
    payload =
      %{}
      |> maybe_put(update, :q, &sanitize_map(&1, obfuscate))
      |> maybe_put(update, :u, &sanitize_map(&1, obfuscate))
      |> maybe_put(update, :multi)
      |> maybe_put(update, :upsert)

    maybe_append_ellipses([payload], rest)
  end

  defp sanitize_deletes([delete | rest] = _deletes, obfuscate) do
    payload =
      %{}
      |> maybe_put(delete, :q, &sanitize_map(&1, obfuscate))
      |> maybe_put(delete, :limit)

    maybe_append_ellipses([payload], rest)
  end

  defp sanitize_pipeline(pipeline, obfuscate) do
    Enum.map(pipeline, &sanitize_map(&1, obfuscate))
  end

  defp maybe_put(payload, command, key, fun \\ & &1) do
    with val when not is_nil(val) <- command[key],
         val when not is_nil(val) <- fun.(val) do
      Map.put(payload, key, val)
    else
      nil ->
        payload
    end
  end

  defp maybe_append_ellipses(list, []), do: list
  defp maybe_append_ellipses(list, _more), do: list ++ ["..."]

  defp maybe_serialize(payload) when map_size(payload) > 0, do: Jason.encode!(payload)
  defp maybe_serialize(_payload), do: nil

  defp sanitize_map(val, obfuscate) when is_map(val) and not is_struct(val),
    do: Map.new(val, fn {k, v} -> {k, sanitize_map(v, obfuscate)} end)

  defp sanitize_map([kv | _] = val, obfuscate) when is_tuple(kv) and tuple_size(kv) == 2,
    do: Map.new(val, fn {k, v} -> {k, sanitize_map(v, obfuscate)} end)

  defp sanitize_map(val, obfuscate) when is_list(val),
    do: Enum.map(val, &sanitize_map(&1, obfuscate))

  defp sanitize_map(_val, true), do: "?"
  defp sanitize_map(val, false) when is_struct(val, BSON.ObjectId), do: BSON.ObjectId.encode!(val)
  defp sanitize_map(val, false), do: val
end
