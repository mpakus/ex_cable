defmodule ExCable.ChannelsTest do
  use ExUnit.Case, async: true

  alias ExCable.TestWire, as: Wire

  @channel ~s({"channel":"ChatChannel", "room":42})
  @second ~s({"channel":"ChatChannel","room":7})
  @denied ~s({"channel":"AdminChannel"})

  setup do
    parent = self()
    account = "user:" <> Integer.to_string(System.unique_integer([:positive]))

    backend =
      Wire.listen(
        {ExCable.TestRPC,
         fn path, body, headers ->
           send(parent, {:rpc, path, body, headers["x-anycable-meta-sid"]})

           reply =
             case {path, body} do
               {"/rpc/connect", _} ->
                 %{status: 1, identifiers: account, env: %{cstate: %{user: "42", obsolete: "x"}}}

               {"/rpc/command", %{"command" => "subscribe", "identifier" => @denied}} ->
                 %{status: 2, streams: ["old"]}

               {"/rpc/command", %{"command" => "subscribe", "identifier" => @channel}} ->
                 %{status: 1, streams: ["old", "other", "old"], env: %{istate: %{room: "42"}}}

               {"/rpc/command", %{"command" => "subscribe", "identifier" => @second}} ->
                 %{status: 1, streams: ["old"]}

               {"/rpc/command",
                %{"command" => "message", "identifier" => @channel, "data" => "switch"}} ->
                 %{
                   status: 1,
                   stop_streams: true,
                   streams: ["replacement"],
                   transmissions: [JSON.encode!(%{identifier: @channel, message: "switched"})]
                 }

               {"/rpc/command", %{"command" => "message", "identifier" => @channel}} ->
                 %{
                   status: 1,
                   stopped_streams: ["old"],
                   streams: ["new"],
                   env: %{cstate: %{obsolete: ""}, istate: %{room: ""}},
                   transmissions: [JSON.encode!(%{identifier: @channel, message: "performed"})]
                 }

               _ ->
                 %{status: 1}
             end

           {200, reply}
         end}
      )

    config = %{
      ExCable.Config.defaults()
      | rpc_url: "http://localhost:#{backend}/rpc",
        broadcast_secret: "broadcast-secret"
    }

    port = Wire.listen({ExCable.HTTP, config})
    client = Wire.connect(port)
    {_, client} = Wire.json(client)
    assert_receive {:rpc, "/rpc/connect", _, sid}
    %{port: port, client: client, sid: sid, account: account}
  end

  test "preserves opaque identifiers, patches state and updates overlapping streams", ctx do
    %{port: port, client: client, sid: sid} = ctx
    client = Wire.command(client, "message", @channel, %{"data" => "{}"})
    client = Wire.command(client, "subscribe", @denied)

    assert {%{"type" => "reject_subscription", "identifier" => @denied}, client} =
             Wire.json(client)

    assert_receive {:rpc, "/rpc/command", %{"command" => "subscribe", "identifier" => @denied},
                    ^sid}

    refute_received {:rpc, "/rpc/command", %{"command" => "message"}, _}

    client = Wire.command(client, "subscribe", @channel)

    assert {%{"type" => "confirm_subscription", "identifier" => @channel}, client} =
             Wire.json(client)

    assert_receive {:rpc, "/rpc/command",
                    %{"identifier" => @channel, "env" => %{"cstate" => %{"user" => "42"}}}, ^sid}

    client = Wire.command(client, "subscribe", @channel)

    assert {%{"type" => "confirm_subscription", "identifier" => @channel}, client} =
             Wire.json(client)

    refute_received {:rpc, "/rpc/command", %{"identifier" => @channel}, _}

    client = Wire.command(client, "subscribe", @second)

    assert {%{"type" => "confirm_subscription", "identifier" => @second}, client} =
             Wire.json(client)

    assert_receive {:rpc, "/rpc/command", %{"identifier" => @second}, ^sid}

    assert 201 == publish(port, %{stream: "old", data: "true"})
    {first, client} = Wire.json(client)
    {second, client} = Wire.json(client)

    assert MapSet.new([first, second]) ==
             MapSet.new([
               %{"identifier" => @channel, "message" => true},
               %{"identifier" => @second, "message" => true}
             ])

    data = ~s({"action":"speak","text":"hi"})
    client = Wire.command(client, "message", @channel, %{"data" => data})
    assert {%{"identifier" => @channel, "message" => "performed"}, client} = Wire.json(client)

    assert_receive {:rpc, "/rpc/command",
                    %{
                      "command" => "message",
                      "data" => ^data,
                      "env" => %{"istate" => %{"room" => "42"}}
                    }, ^sid}

    assert 201 ==
             publish(port, [
               %{stream: "old", data: "1"},
               %{stream: "new", data: ~s({"text":"hello"})},
               %{stream: "other", data: "null"}
             ])

    assert {%{"identifier" => @second, "message" => 1}, client} = Wire.json(client)

    assert {%{"identifier" => @channel, "message" => %{"text" => "hello"}}, client} =
             Wire.json(client)

    assert {%{"identifier" => @channel, "message" => nil}, client} = Wire.json(client)

    client = Wire.command(client, "unsubscribe", @channel)
    assert_receive {:rpc, "/rpc/command", %{"command" => "unsubscribe", "env" => env}, ^sid}
    assert env["cstate"] == %{"user" => "42"}
    refute Map.has_key?(env, "istate")

    assert 201 == publish(port, [%{stream: "new", data: "2"}, %{stream: "old", data: "3"}])
    assert {%{"identifier" => @second, "message" => 3}, client} = Wire.json(client)
    Wire.close(client)
    assert_receive {:rpc, "/rpc/disconnect", %{"subscriptions" => [@second]}, ^sid}
  end

  test "requires a broadcast secret, validates whole batches, and remotely disconnects", ctx do
    %{port: port, client: client, account: account, sid: sid} = ctx
    payload = %{command: "disconnect", payload: %{identifier: account, reconnect: false}}
    assert 401 == publish(port, payload, "wrong")

    assert 422 ==
             publish(port, [
               %{stream: "valid", data: "1"},
               %{stream: "broken", data: "invalid JSON"}
             ])

    assert 422 == publish(port, %{stream: "invalid", data: %{}})
    assert 413 == publish(port, :binary.copy("x", 65_537))
    assert 201 == publish(port, payload)

    assert {%{"type" => "disconnect", "reason" => "remote", "reconnect" => false}, client} =
             Wire.json(client)

    assert {{:close, 1000, _}, client} = Wire.next(client)
    Wire.close(client)
    assert_receive {:rpc, "/rpc/disconnect", %{"identifiers" => ^account}, ^sid}
  end

  test "stop_streams clears every old membership before adding replacements", ctx do
    %{port: port, client: client} = ctx
    client = Wire.command(client, "subscribe", @channel)
    assert {%{"type" => "confirm_subscription"}, client} = Wire.event(client)

    client = Wire.command(client, "message", @channel, %{"data" => "switch"})
    assert {%{"message" => "switched"}, client} = Wire.event(client)

    assert 201 ==
             publish(port, [
               %{stream: "old", data: "1"},
               %{stream: "other", data: "2"},
               %{stream: "replacement", data: "3"}
             ])

    assert {%{"identifier" => @channel, "message" => 3}, client} = Wire.event(client)
    Wire.close(client)
  end

  defp publish(port, body, secret \\ "broadcast-secret") do
    body = if is_binary(body), do: body, else: JSON.encode!(body)

    {:ok, response} =
      Finch.build(
        :post,
        "http://localhost:#{port}/_broadcast",
        [{"authorization", "Bearer " <> secret}],
        body
      )
      |> Finch.request(ExCable.Finch)

    response.status
  end
end
