defmodule ExCable.RedisTest do
  use ExUnit.Case
  alias ExCable.TestWire, as: Wire

  if is_nil(System.get_env("EX_CABLE_TEST_VALKEY")), do: @moduletag(:external)

  test "two BEAM instances receive Redis broadcasts and recover after their Redis connection drops" do
    {valkey, redis_url} = start_valkey()
    redis = start_supervised!({Redix, redis_url})
    await(fn -> Redix.command(redis, ["PING"]) == {:ok, "PONG"} end)

    id = ~s({"channel":"CommonChannel"})
    channel = "test-cable"

    backend =
      Wire.listen(
        {ExCable.TestRPC,
         fn
           "/rpc/connect", _, _ -> {200, %{status: 1, identifiers: "shared-user"}}
           "/rpc/command", _, _ -> {200, %{status: 1, streams: ["shared-room"]}}
           "/rpc/disconnect", _, _ -> {200, %{status: 1}}
         end}
      )

    config = %{
      ExCable.Config.defaults()
      | port: 0,
        redis_url: redis_url,
        redis_channel: channel,
        rpc_url: "http://127.0.0.1:#{backend}/rpc"
    }

    start_supervised!(%{
      id: :local_broker,
      start:
        {Supervisor, :start_link, [ExCable.Redis.children(config), [strategy: :rest_for_one]]}
    })

    local_port = Wire.listen({ExCable.HTTP, config})

    {:ok, peer, _} = :peer.start_link(%{connection: :standard_io, args: [~c"+S", ~c"2:2"]})
    on_exit(fn -> if Process.alive?(peer), do: :peer.stop(peer) end)
    :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
    replica_port = :peer.call(peer, ExCable.TestReplica, :start, [config])
    await(fn -> health(local_port) == 200 and health(replica_port) == 200 end)

    clients =
      for port <- [local_port, replica_port] do
        client = Wire.connect(port)
        assert {%{"type" => "welcome"}, client} = Wire.event(client)
        client = Wire.command(client, "subscribe", id)
        assert {%{"type" => "confirm_subscription"}, client} = Wire.event(client)
        client
      end

    broadcast = fn value ->
      payload = JSON.encode!(%{stream: "shared-room", data: JSON.encode!(value)})
      assert {:ok, 2} = Redix.command(redis, ["PUBLISH", channel, payload])
    end

    broadcast.(1)
    clients = receive_from_both(clients, id, 1)

    assert {:ok, 2} = Redix.command(redis, ["CLIENT", "KILL", "TYPE", "pubsub"])
    await(fn -> health(local_port) == 503 and health(replica_port) == 503 end)
    await(fn -> health(local_port) == 200 and health(replica_port) == 200 end, 150)

    broadcast.(2)
    clients = receive_from_both(clients, id, 2)

    disconnect =
      JSON.encode!(%{
        command: "disconnect",
        payload: %{identifier: "shared-user", reconnect: true}
      })

    assert {:ok, 2} = Redix.command(redis, ["PUBLISH", channel, disconnect])

    for client <- clients do
      assert {%{"type" => "disconnect", "reason" => "remote", "reconnect" => true}, client} =
               Wire.event(client)

      Wire.close(client)
    end

    :peer.stop(peer)
    Redix.command(redis, ["SHUTDOWN", "NOSAVE"])
    if Port.info(valkey), do: Port.close(valkey)
  end

  defp receive_from_both(clients, id, value) do
    Enum.map(clients, fn client ->
      assert {%{"identifier" => ^id, "message" => ^value}, client} = Wire.event(client)
      client
    end)
  end

  defp start_valkey do
    executable = System.fetch_env!("EX_CABLE_TEST_VALKEY")
    {:ok, listener} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, {_, port}} = :inet.sockname(listener)
    :gen_tcp.close(listener)

    child =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 512},
        {:args,
         [
           "--bind",
           "127.0.0.1",
           "--port",
           to_string(port),
           "--save",
           "",
           "--appendonly",
           "no",
           "--dir",
           System.tmp_dir!()
         ]}
      ])

    on_exit(fn ->
      case :gen_tcp.connect({127, 0, 0, 1}, port, [], 250) do
        {:ok, socket} ->
          :gen_tcp.send(socket, "SHUTDOWN NOSAVE\r\n")
          :gen_tcp.close(socket)

        {:error, _} ->
          :ok
      end
    end)

    {child, "redis://127.0.0.1:#{port}"}
  end

  defp health(port) do
    {:ok, result} =
      Finch.build(:get, "http://127.0.0.1:#{port}/healthz") |> Finch.request(ExCable.Finch)

    result.status
  end

  defp await(predicate, retries \\ 50) do
    cond do
      predicate.() ->
        :ok

      retries == 0 ->
        flunk("Condition did not become true")

      true ->
        Process.sleep(20)
        await(predicate, retries - 1)
    end
  end
end
