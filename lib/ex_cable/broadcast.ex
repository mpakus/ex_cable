defmodule ExCable.Broadcast do
  @registry ExCable.Registry
  @max_pending 128
  @max_size 65_536

  def max_size, do: @max_size

  def budget, do: :atomics.new(2, signed: false)

  def join_stream(stream, identifier, sid, budget) do
    membership = make_ref()

    {:ok, _} =
      Registry.register(@registry, {:stream, stream}, {identifier, membership, sid, budget})

    membership
  end

  def leave_stream(stream, identifier) do
    Registry.unregister_match(@registry, {:stream, stream}, {identifier, :_, :_, :_})
  end

  def join_connection(identifiers, budget),
    do: Registry.register(@registry, {:connection, identifiers}, budget)

  def leave_connection(identifiers),
    do: Registry.unregister(@registry, {:connection, identifiers})

  def received(budget), do: :atomics.sub(budget, 1, 1)

  def ingest(body) when byte_size(body) <= @max_size do
    with {:ok, payload} <- JSON.decode(body),
         {:ok, events} <- parse(payload) do
      Enum.each(events, &publish/1)
      :ok
    else
      _ -> :error
    end
  end

  def ingest(_), do: :error

  defp parse(%{"command" => "disconnect", "payload" => %{"identifier" => id} = payload})
       when is_binary(id) and id != "" do
    case Map.get(payload, "reconnect", false) do
      reconnect when is_boolean(reconnect) -> {:ok, [{:disconnect, id, reconnect}]}
      _ -> :error
    end
  end

  defp parse(%{} = payload), do: parse([payload])

  defp parse([_ | _] = payload) do
    Enum.reduce_while(payload, {:ok, []}, fn
      %{"stream" => stream, "data" => data} = payload, {:ok, events}
      when is_binary(stream) and stream != "" and is_binary(data) ->
        case JSON.decode(data) do
          {:ok, _} -> {:cont, {:ok, [{:stream, stream, data, excluded_socket(payload)} | events]}}
          {:error, _} -> {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      :error -> :error
    end
  end

  defp parse(_), do: :error

  defp excluded_socket(%{"meta" => %{"exclude_socket" => sid}}) when is_binary(sid), do: sid
  defp excluded_socket(_), do: nil

  defp publish({:stream, stream, data, excluded}) do
    ExCable.Stats.increment(:publications)

    Registry.dispatch(@registry, {:stream, stream}, fn entries ->
      Enum.each(entries, fn
        {_, {_, _, ^excluded, _}} ->
          :ok

        {pid, {identifier, membership, _, budget}} ->
          enqueue(pid, budget, {:broadcast, stream, identifier, membership, data})
      end)
    end)
  end

  defp publish({:disconnect, identifiers, reconnect}) do
    Registry.dispatch(@registry, {:connection, identifiers}, fn entries ->
      Enum.each(entries, fn {pid, budget} ->
        enqueue(pid, budget, {:remote_disconnect, reconnect})
      end)
    end)
  end

  defp enqueue(pid, budget, message) do
    if :atomics.get(budget, 2) == 0 do
      if :atomics.add_get(budget, 1, 1) <= @max_pending do
        send(pid, message)
      else
        if :atomics.exchange(budget, 2, 1) == 0 do
          ExCable.Stats.increment(:slow_consumers)
          send(pid, :slow_consumer)
        end

        received(budget)
      end
    end
  end
end
