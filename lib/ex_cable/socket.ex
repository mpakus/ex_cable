defmodule ExCable.Socket do
  @behaviour WebSock
  alias ExCable.{Broadcast, RPC}

  @impl true
  def init({config, env}) do
    sid = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    state = %{
      config: config,
      sid: sid,
      env: env,
      identifiers: nil,
      awaiting_pong: nil,
      subscriptions: %{},
      budget: Broadcast.budget()
    }

    case RPC.connect(config, sid, env) do
      {:ok, %{"status" => 1} = reply} ->
        state = %{state | identifiers: value(reply, "identifiers", "")} |> patch_connection(reply)
        Broadcast.join_connection(state.identifiers, state.budget)
        half = div(config.heartbeat, 2)
        schedule_ping(half + :rand.uniform(half))
        {:push, frames(reply, %{"type" => "welcome"}), state}

      {:ok, %{"status" => 2} = reply} ->
        finish(state, frames(reply, disconnect_message("unauthorized", false)))

      _ ->
        disconnect(state, "server_restart", true)
    end
  end

  @impl true
  def handle_in({data, opcode: :text}, state) do
    with {:ok, %{"command" => command, "identifier" => id} = message} <- JSON.decode(data),
         true <- is_binary(id) and id != "" do
      handle_command(command, id, message["data"], state)
    else
      _ -> {:ok, state}
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  def handle_info(:heartbeat, %{awaiting_pong: token} = state) when not is_nil(token),
    do: disconnect(state, "server_restart", true)

  def handle_info(:heartbeat, state) do
    token = <<System.unique_integer([:positive])::unsigned-64>>
    schedule_ping(state.config.heartbeat)
    ping = %{"type" => "ping", "message" => System.system_time(:second)}
    {:push, [text(ping), {:ping, token}], %{state | awaiting_pong: token}}
  end

  def handle_info({:broadcast, _, _, _, _} = first, state) do
    remaining = Broadcast.received(state.budget)
    frame = broadcast_frame(first, state)
    extra = if remaining > 0, do: ready_broadcasts(), else: []

    case extra do
      [] when is_nil(frame) ->
        {:ok, state}

      [] ->
        {:push, frame, state}

      _ ->
        frames = for message <- extra, next = take_frame(message, state), do: next
        {:push, if(frame, do: [frame | frames], else: frames), state}
    end
  end

  def handle_info({:remote_disconnect, reconnect}, state),
    do: disconnect(state, "remote", reconnect)

  def handle_info(:slow_consumer, state), do: disconnect(state, "server_restart", true)
  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def handle_control({token, opcode: :pong}, %{awaiting_pong: token} = state),
    do: {:ok, %{state | awaiting_pong: nil}}

  def handle_control(_frame, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{identifiers: nil}), do: :ok

  def terminate(_reason, state) do
    Broadcast.leave_connection(state.identifiers)

    for {id, sub} <- state.subscriptions, stream <- Map.keys(sub.streams) do
      Broadcast.leave_stream(stream, id)
    end

    RPC.disconnect(
      state.config,
      state.sid,
      state.identifiers,
      state.env,
      Map.keys(state.subscriptions)
    )
  end

  # Snapshot only when more broadcasts were admitted. A selective receive alone
  # could skip a TCP command, heartbeat or disconnect in front of a broadcast.
  defp ready_broadcasts do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, n} when n in 1..128 ->
        {:messages, queue} = Process.info(self(), :messages)
        queue |> Enum.take(3) |> Enum.take_while(&match?({:broadcast, _, _, _, _}, &1))

      _ ->
        []
    end
  end

  defp take_frame(message, state) do
    receive do
      ^message ->
        Broadcast.received(state.budget)
        broadcast_frame(message, state)
    after
      0 -> nil
    end
  end

  defp broadcast_frame({:broadcast, stream, id, membership, data}, state) do
    case state.subscriptions do
      %{^id => %{streams: %{^stream => ^membership}, encoded_id: encoded_id}} ->
        {:text, [~s({"identifier":), encoded_id, ~s(,"message":), data, "}"]}

      _ ->
        nil
    end
  end

  defp handle_command("subscribe", id, _, state) do
    cond do
      Map.has_key?(state.subscriptions, id) ->
        {:push, text(subscription("confirm_subscription", id)), state}

      map_size(state.subscriptions) >= 256 or byte_size(id) > 8_192 ->
        {:push, text(subscription("reject_subscription", id)), state}

      true ->
        execute("subscribe", id, nil, state)
    end
  end

  defp handle_command("unsubscribe", id, _, state) do
    if Map.has_key?(state.subscriptions, id),
      do: execute("unsubscribe", id, nil, state),
      else: {:ok, state}
  end

  defp handle_command("message", id, data, state) when is_binary(data) do
    if Map.has_key?(state.subscriptions, id),
      do: execute("message", id, data, state),
      else: {:ok, state}
  end

  defp handle_command(_, _, _, state), do: {:ok, state}

  defp execute(command, id, data, state) do
    sub =
      Map.get(state.subscriptions, id, %{streams: %{}, istate: %{}, encoded_id: JSON.encode!(id)})

    env =
      if map_size(sub.istate) == 0, do: state.env, else: Map.put(state.env, "istate", sub.istate)

    payload = %{
      "command" => command,
      "identifier" => id,
      "connection_identifiers" => state.identifiers,
      "env" => env
    }

    payload = if data, do: Map.put(payload, "data", data), else: payload

    case RPC.request(state.config, state.sid, "command", payload) do
      {:ok, %{"status" => 1} = reply} ->
        state
        |> patch_connection(reply)
        |> update_subscription(command, id, sub, reply)
        |> command_reply(command, id, reply, true)

      {:ok, %{"status" => 2} = reply} when command != "unsubscribe" ->
        command_reply(state, command, id, reply, false)

      _ ->
        disconnect(state, "server_restart", true)
    end
  end

  defp update_subscription(state, "unsubscribe", id, sub, _reply) do
    remove_streams(sub.streams, Map.keys(sub.streams), id)
    %{state | subscriptions: Map.delete(state.subscriptions, id)}
  end

  defp update_subscription(state, _command, id, sub, reply) do
    stopped =
      if reply["stop_streams"] == true,
        do: Map.keys(sub.streams),
        else: list(reply, "stopped_streams")

    streams = remove_streams(sub.streams, stopped, id)

    streams =
      Enum.reduce(list(reply, "streams"), streams, fn stream, streams ->
        Map.put_new_lazy(streams, stream, fn ->
          Broadcast.join_stream(stream, id, state.sid, state.budget)
        end)
      end)

    sub = %{sub | streams: streams, istate: patch(sub.istate, state_patch(reply, "istate"))}
    %{state | subscriptions: Map.put(state.subscriptions, id, sub)}
  end

  defp remove_streams(streams, stopped, id) do
    Enum.reduce(stopped, streams, fn stream, streams ->
      if Map.has_key?(streams, stream), do: Broadcast.leave_stream(stream, id)
      Map.delete(streams, stream)
    end)
  end

  defp patch_connection(state, reply) do
    cstate = patch(Map.get(state.env, "cstate", %{}), state_patch(reply, "cstate"))

    env =
      if map_size(cstate) == 0,
        do: Map.delete(state.env, "cstate"),
        else: Map.put(state.env, "cstate", cstate)

    %{state | env: env}
  end

  defp state_patch(%{"env" => %{} = env}, key), do: Map.get(env, key)
  defp state_patch(_, _), do: nil

  defp patch(current, updates) when is_map(updates) do
    Enum.reduce(updates, current, fn
      {key, ""}, acc -> Map.delete(acc, key)
      {key, value}, acc when is_binary(value) -> Map.put(acc, key, value)
      _, acc -> acc
    end)
  end

  defp patch(current, _), do: current

  defp command_reply(state, command, id, reply, success?) do
    fallback =
      if command == "subscribe" do
        subscription(if(success?, do: "confirm_subscription", else: "reject_subscription"), id)
      end

    if reply["disconnect"] == true do
      finish(state, frames(reply, disconnect_message("unauthorized", false)))
    else
      {:push, frames(reply, fallback), state}
    end
  end

  defp schedule_ping(delay), do: Process.send_after(self(), :heartbeat, delay)

  defp disconnect(state, reason, reconnect),
    do: finish(state, [text(disconnect_message(reason, reconnect))])

  defp disconnect_message(reason, reconnect),
    do: %{"type" => "disconnect", "reason" => reason, "reconnect" => reconnect}

  defp finish(state, frames), do: {:stop, :normal, 1000, frames, state}

  defp subscription(type, id), do: %{"type" => type, "identifier" => id}

  defp frames(reply, fallback) do
    frames =
      for raw <- list(reply, "transmissions"),
          {:ok, %{} = message} <- [JSON.decode(raw)],
          do: {raw, message}

    output = Enum.map(frames, fn {raw, _} -> {:text, raw} end)

    if fallback &&
         !Enum.any?(frames, fn {_, message} ->
           Map.take(message, ["type", "identifier"]) == Map.take(fallback, ["type", "identifier"])
         end) do
      output ++ [text(fallback)]
    else
      output
    end
  end

  defp list(map, key) do
    case Map.get(map, key) do
      entries when is_list(entries) -> Enum.filter(entries, &is_binary/1)
      _ -> []
    end
  end

  defp value(map, key, default) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _ -> default
    end
  end

  defp text(message), do: {:text, JSON.encode_to_iodata!(message)}
end
