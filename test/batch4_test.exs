defmodule ExCable.Batch4Test do
  use ExUnit.Case, async: false
  alias ExCable.Broadcast
  alias ExCable.TestWire, as: Wire

  setup do
    backend =
      Wire.listen(
        {ExCable.TestRPC,
         fn
           "/rpc/connect", _, _ -> {200, %{status: 1, identifiers: "batch4-user"}}
           "/rpc/command", _, _ -> {200, %{status: 1, streams: ["batch4"]}}
           "/rpc/disconnect", _, _ -> {200, %{status: 1}}
         end}
      )

    config = %{
      ExCable.Config.defaults()
      | heartbeat: 60_000,
        rpc_url: "http://127.0.0.1:#{backend}/rpc"
    }

    port = Wire.listen({ExCable.HTTP, config})
    client = subscribe(port)
    [{pid, {"room", _, _, budget}}] = Registry.lookup(ExCable.Registry, {:stream, "batch4"})

    handler = make_ref()

    :ok =
      :telemetry.attach(
        handler,
        [:thousand_island, :connection, :send],
        &__MODULE__.sent/4,
        {self(), pid}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{port: port, client: client, pid: pid, budget: budget}
  end

  def sent(_, %{data: bytes}, _, {test, pid}) when self() == pid,
    do: send(test, {:write, IO.iodata_to_binary(bytes)})

  def sent(_, _, _, _), do: :ok

  test "writes at most four frames, preserves heartbeat order and skips stale memberships", ctx do
    while_suspended(ctx.pid, fn ->
      for n <- 1..5, do: publish(n)
      send(ctx.pid, :heartbeat)
      publish(6)
      :atomics.add(ctx.budget, 1, 1)
      send(ctx.pid, {:broadcast, "batch4", "room", make_ref(), "999"})
      for n <- 7..9, do: publish(n)
    end)

    client = Enum.reduce(1..9, ctx.client, &read_event/2)
    assert next_write(client) == [1, 2, 3, 4]
    assert next_write(client) == [5]
    assert next_write(client) == ["ping"]
    assert next_write(client) == [:ping]
    assert next_write(client) == [6, 7, 8]
    assert next_write(client) == [9]
    assert :atomics.get(ctx.budget, 1) == 0
    Wire.close(client)
  end

  test "a lone broadcast is sent while the publisher is idle", ctx do
    publish(10)
    assert next_write(ctx.client) == [10]
    Wire.close(read_event(10, ctx.client))
  end

  test "a stale broadcast is discarded before the next heartbeat", ctx do
    :atomics.add(ctx.budget, 1, 1)
    send(ctx.pid, {:broadcast, "batch4", "room", make_ref(), "999"})
    send(ctx.pid, :heartbeat)
    assert next_write(ctx.client) == ["ping"]
    assert next_write(ctx.client) == [:ping]
    assert :atomics.get(ctx.budget, 1) == 0
    Wire.close(ctx.client)
  end

  test "a queued remote disconnect precedes later broadcasts", ctx do
    while_suspended(ctx.pid, fn ->
      publish(1)
      publish(2)

      assert :ok =
               Broadcast.ingest(
                 JSON.encode!(%{command: "disconnect", payload: %{identifier: "batch4-user"}})
               )

      publish(3)
    end)

    client = Enum.reduce(1..2, ctx.client, &read_event/2)

    assert {%{"type" => "disconnect", "reason" => "remote", "reconnect" => false}, client} =
             Wire.event(client)

    assert next_write(client) == [1, 2]
    assert next_write(client) == ["disconnect"]
    Wire.close(client)
  end

  test "a stalled socket drains its 128 admitted broadcasts before disconnecting", ctx do
    healthy = subscribe(ctx.port)

    healthy =
      while_suspended(ctx.pid, fn ->
        client =
          Enum.reduce(1..160, healthy, fn n, client ->
            publish(n)
            read_event(n, client)
          end)

        assert :atomics.get(ctx.budget, 1) == 128
        assert :atomics.get(ctx.budget, 2) == 1
        client
      end)

    slow = Enum.reduce(1..128, ctx.client, &read_event/2)
    assert {%{"type" => "disconnect", "reconnect" => true}, slow} = Wire.event(slow)
    for chunk <- Enum.chunk_every(1..128, 4), do: assert(next_write(slow) == chunk)
    assert next_write(slow) == ["disconnect"]
    assert :atomics.get(ctx.budget, 1) == 0
    publish(161)
    Wire.close(read_event(161, healthy))
    Wire.close(slow)
  end

  defp subscribe(port) do
    assert {%{"type" => "welcome"}, client} = port |> Wire.connect() |> Wire.event()

    assert {%{"type" => "confirm_subscription"}, client} =
             client |> Wire.command("subscribe", "room") |> Wire.event()

    client
  end

  defp while_suspended(pid, fun) do
    :ok = :sys.suspend(pid)

    try do
      fun.()
    after
      :sys.resume(pid)
    end
  end

  defp publish(n),
    do: assert(:ok == Broadcast.ingest(JSON.encode!(%{stream: "batch4", data: to_string(n)})))

  defp read_event(n, client) do
    assert {%{"identifier" => "room", "message" => ^n}, client} = Wire.event(client)
    client
  end

  defp next_write(client) do
    assert_receive {:write, bytes}, 1_000
    {:ok, _, frames} = Mint.WebSocket.decode(client.ws, bytes)

    Enum.map(frames, fn
      {:text, json} ->
        body = JSON.decode!(json)
        body["type"] || Map.fetch!(body, "message")

      {:ping, _} ->
        :ping
    end)
  end
end
