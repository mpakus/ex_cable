defmodule ExCable.RPCTest do
  use ExUnit.Case, async: true
  alias ExCable.{RPC, TestWire}

  test "classifies HTTP authentication, malformed responses and failed transport" do
    backend =
      TestWire.listen(
        {ExCable.TestRPC,
         fn
           "/rpc/authentication", _, _ -> {401, %{}}
           "/rpc/malformed", _, _ -> {200, []}
         end}
      )

    config = config(backend)
    assert RPC.request(config, "sid", "authentication", %{}) == {:error, :rpc_authentication}
    assert RPC.request(config, "sid", "malformed", %{}) == {:error, :invalid_response}

    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, {_, closed_port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    assert RPC.connect(config(closed_port), "sid", %{}) == {:error, :rpc_unavailable}
  end

  test "decodes large RPC responses" do
    transmission = String.duplicate("x", 300_000)

    backend =
      TestWire.listen(
        {ExCable.TestRPC,
         fn _, _, _ ->
           {200, %{status: 1, transmissions: [transmission]}}
         end}
      )

    assert {:ok, %{"status" => 1, "transmissions" => [^transmission]}} =
             RPC.connect(config(backend), "sid", %{})
  end

  test "pool exhaustion returns an error to the socket while the active request completes" do
    parent = self()

    backend =
      TestWire.listen(
        {ExCable.TestRPC,
         fn _, _, _ ->
           send(parent, {:active, self()})

           receive do
             :complete -> {200, %{status: 1}}
           after
             1_000 -> {503, %{}}
           end
         end}
      )

    config = config(backend)
    :ok = Finch.start_pool(ExCable.Finch, Finch.Pool.new(config.rpc_url), size: 1)
    active = Task.async(fn -> RPC.connect(config, "sid-1", %{}) end)
    assert_receive {:active, request_pid}, 1_000

    assert RPC.connect(%{config | rpc_timeout: 25}, "sid-2", %{}) == {:error, :rpc_unavailable}
    send(request_pid, :complete)
    assert {:ok, %{"status" => 1}} = Task.await(active)
  end

  @tag capture_log: true
  test "a failed callback reaches the supervised disconnect worker" do
    parent = self()

    backend =
      TestWire.listen(
        {ExCable.TestRPC,
         fn path, body, _ ->
           send(parent, {:callback, path, body})
           {503, %{}}
         end}
      )

    assert :ok == RPC.disconnect(config(backend), "sid", "subscriber", %{}, ["room"])

    assert_receive {:callback, "/rpc/disconnect",
                    %{"identifiers" => "subscriber", "subscriptions" => ["room"]}}
  end

  defp config(port), do: %{ExCable.Config.defaults() | rpc_url: "http://127.0.0.1:#{port}/rpc"}
end
