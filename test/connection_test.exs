defmodule ExCable.ConnectionTest do
  use ExUnit.Case, async: true

  alias ExCable.TestWire, as: Wire

  test "negotiates Action Cable, forwards the request context, welcomes and sends a heartbeat" do
    parent = self()

    backend =
      Wire.listen(
        {ExCable.TestRPC,
         fn path, body, headers ->
           send(parent, {:rpc, path, body, headers})
           {200, %{status: 1, identifiers: "user:1"}}
         end}
      )

    port = Wire.listen({ExCable.HTTP, config(backend)})

    headers = [
      {"sec-websocket-protocol", "unsupported, actioncable-v1-json"},
      {"origin", "https://app.example"},
      {"cookie", "session=123"},
      {"x-ignored", "private"}
    ]

    client = Wire.connect(port, headers, "/cable?locale=en")
    assert {%{"type" => "welcome"}, client} = Wire.json(client)

    assert_receive {:rpc, "/rpc/connect", %{"env" => env}, rpc_headers}
    assert env["url"] == "wss://app.example/cable?locale=en"
    assert env["headers"] == %{"cookie" => "session=123", "origin" => "https://app.example"}
    assert rpc_headers["authorization"] == "Bearer rpc-secret"
    assert rpc_headers["x-anycable-meta-sid"] != ""
    assert rpc_headers["x-anycable-meta-protov"] == "v1"

    assert {%{"type" => "ping", "message" => time}, client} = Wire.json(client)
    assert abs(time - System.system_time(:second)) <= 1
    assert {{:ping, token}, client} = Wire.next(client)
    client = Wire.send_frame(client, {:pong, token})
    assert {%{"type" => "ping"}, client} = Wire.json(client)
    Wire.close(client)
    assert_receive {:rpc, "/rpc/disconnect", %{"identifiers" => "user:1"}, _}
  end

  test "rejects foreign origins and unsupported subprotocols before calling Rails" do
    port = Wire.listen({ExCable.HTTP, config(1)})
    protocol = {"sec-websocket-protocol", "actioncable-v1-json"}
    {conn, _, 403, _, _} = Wire.open(port, [protocol, {"origin", "https://evil.example"}])
    Mint.HTTP.close(conn)

    {conn, _, 400, _, _} =
      Wire.open(port, [{"sec-websocket-protocol", "actioncable-unsupported"}])

    Mint.HTTP.close(conn)
  end

  test "a rejected connection sends a non-reconnecting disconnect" do
    parent = self()

    backend =
      Wire.listen(
        {ExCable.TestRPC,
         fn path, _, _ ->
           send(parent, path)
           {200, %{status: 2}}
         end}
      )

    port = Wire.listen({ExCable.HTTP, config(backend)})
    client = Wire.connect(port)

    assert {%{"type" => "disconnect", "reason" => "unauthorized", "reconnect" => false}, client} =
             Wire.json(client)

    assert {{:close, 1000, _}, client} = Wire.next(client)
    Wire.close(client)
    assert_received "/rpc/connect"
    refute_receive "/rpc/disconnect"
  end

  test "a Rails transport failure closes with a reconnect hint" do
    backend = Wire.listen({ExCable.TestRPC, fn _, _, _ -> {503, %{}} end})
    port = Wire.listen({ExCable.HTTP, config(backend)})
    client = Wire.connect(port)

    assert {%{"type" => "disconnect", "reason" => "server_restart", "reconnect" => true}, client} =
             Wire.json(client)

    assert {{:close, 1000, _}, client} = Wire.next(client)
    Wire.close(client)
  end

  test "checks native WebSocket pong and cleans up an unresponsive connection" do
    parent = self()

    backend =
      Wire.listen(
        {ExCable.TestRPC,
         fn path, _, _ ->
           send(parent, path)
           {200, %{status: 1}}
         end}
      )

    port = Wire.listen({ExCable.HTTP, config(backend)})
    client = Wire.connect(port)
    assert {%{"type" => "welcome"}, client} = Wire.json(client)
    assert {%{"type" => "ping"}, client} = Wire.json(client)
    assert {{:ping, _}, client} = Wire.next(client)
    assert {%{"type" => "disconnect", "reconnect" => true}, client} = Wire.json(client)
    Wire.close(client)
    assert_receive "/rpc/disconnect"
  end

  test "accepts a native client without a subprotocol and disables HTTP ingress without a key" do
    backend = Wire.listen({ExCable.TestRPC, fn _, _, _ -> {200, %{status: 1}} end})
    port = Wire.listen({ExCable.HTTP, config(backend)})
    {conn, _, 101, headers, _} = Wire.open(port, [])
    refute List.keymember?(headers, "sec-websocket-protocol", 0)
    Mint.HTTP.close(conn)

    for {method, path} <- [{:post, "/_broadcast"}, {:get, "/unknown"}] do
      assert {:ok, %{status: 404}} =
               Finch.build(method, "http://localhost:#{port}" <> path)
               |> Finch.request(ExCable.Finch)
    end
  end

  defp config(port) do
    Map.merge(ExCable.Config.defaults(), %{
      rpc_url: "http://localhost:#{port}/rpc",
      rpc_secret: "rpc-secret",
      public_url: "https://app.example",
      origins: ["https://app.example"],
      heartbeat: 75
    })
  end
end
