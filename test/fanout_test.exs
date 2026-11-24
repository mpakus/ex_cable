defmodule ExCable.FanoutTest do
  use ExUnit.Case, async: true
  alias ExCable.TestWire, as: Wire

  test "32 socket processes receive every publication in order" do
    parent = self()
    id = ~s({"channel":"FanoutChannel"})

    backend =
      Wire.listen(
        {ExCable.TestRPC,
         fn
           "/rpc/connect", _, _ -> {200, %{status: 1}}
           "/rpc/command", _, _ -> {200, %{status: 1, streams: ["fanout"]}}
           "/rpc/disconnect", _, _ -> {200, %{status: 1}}
         end}
      )

    port =
      Wire.listen(
        {ExCable.HTTP, %{ExCable.Config.defaults() | rpc_url: "http://127.0.0.1:#{backend}/rpc"}}
      )

    clients =
      for _ <- 1..32 do
        Task.async(fn ->
          client = Wire.connect(port)
          assert {%{"type" => "welcome"}, client} = Wire.event(client)
          client = Wire.command(client, "subscribe", id)
          assert {%{"type" => "confirm_subscription"}, client} = Wire.event(client)
          send(parent, :subscribed)

          client =
            Enum.reduce(1..32, client, fn number, client ->
              assert {%{"identifier" => ^id, "message" => ^number}, client} = Wire.event(client)
              client
            end)

          Wire.close(client)
          :ok
        end)
      end

    for _ <- clients, do: assert_receive(:subscribed, 2_000)

    for number <- 1..32 do
      assert :ok ==
               ExCable.Broadcast.ingest(
                 JSON.encode!(%{stream: "fanout", data: to_string(number)})
               )
    end

    assert Task.await_many(clients, 5_000) == List.duplicate(:ok, 32)
  end
end
