defmodule ExCable.RailsTest do
  use ExUnit.Case, async: true
  alias ExCable.TestWire, as: Wire

  if is_nil(System.get_env("EX_CABLE_RAILS_RUBY")), do: @moduletag(:external)

  test "Rails authorizes cookies and rooms, restores channel state, broadcasts and runs callbacks" do
    # Reserve the gateway port before passing its broadcast URL to the Ruby fixture.
    {:ok, listener} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, {_, port}} = :inet.sockname(listener)
    secret = "cross-language-fixture"
    {ruby, rails_port} = start_rails(port, secret)
    :gen_tcp.close(listener)
    start_gateway(port, rails_port, secret)
    assert %{status: 200, body: "ok"} = request(port, "/healthz")

    {rejected, _, 403, _, _} = Wire.open(port, [{"origin", "http://untrusted.example"}])
    Mint.HTTP.close(rejected)

    denied = Wire.connect(port)

    assert {%{"type" => "disconnect", "reason" => "unauthorized", "reconnect" => false}, denied} =
             Wire.event(denied)

    Wire.close(denied)

    headers = [
      {"sec-websocket-protocol", "actioncable-v1-json"},
      {"origin", "http://localhost:3000"},
      {"cookie", "test_account=42"}
    ]

    client = Wire.connect(port, headers)
    assert {%{"type" => "welcome"}, client} = Wire.event(client)

    room = ~s({"channel":"ChatChannel","room":42})
    denied_room = ~s({"channel":"ChatChannel","room":99})
    second_room = ~s({"channel":"ChatChannel","room":7})
    client = Wire.command(client, "subscribe", denied_room)

    assert {%{"type" => "reject_subscription", "identifier" => ^denied_room}, client} =
             Wire.event(client)

    client = Wire.command(client, "subscribe", room)

    assert {%{"type" => "confirm_subscription", "identifier" => ^room}, client} =
             Wire.event(client)

    client =
      Wire.command(client, "message", room, %{"data" => ~s({"action":"speak","text":"hello"})})

    assert {%{
              "identifier" => ^room,
              "message" => %{"account" => "42", "room" => 42, "text" => "hello"}
            }, client} =
             Wire.event(client)

    assert %{status: 202} = request(rails_port, "/broadcast")

    assert {%{"identifier" => ^room, "message" => %{"text" => "from Rails"}}, client} =
             Wire.event(client)

    client = Wire.command(client, "unsubscribe", room)

    client = Wire.command(client, "subscribe", second_room)

    assert {%{"type" => "confirm_subscription", "identifier" => ^second_room}, client} =
             Wire.event(client)

    assert %{status: 202} = request(rails_port, "/disconnect")

    assert {%{"type" => "disconnect", "reason" => "remote", "reconnect" => false}, client} =
             Wire.event(client)

    Wire.close(client)

    assert ["unsubscribe:99", "unsubscribe:42", "unsubscribe:7", "disconnect:42"] =
             await_events(rails_port, [])

    Port.close(ruby)
  end

  defp start_gateway(port, rails_port, secret) do
    case System.get_env("EX_CABLE_DOCKER_IMAGE") do
      nil ->
        config = ExCable.Config.from_env(false, &if(&1 == "ANYCABLE_SECRET", do: secret))

        config = %{
          config
          | port: port,
            origins: ["http://localhost:3000"],
            rpc_url: "http://127.0.0.1:#{rails_port}/_anycable"
        }

        start_supervised!(ExCable.HTTP.listener(config))

      image ->
        {host, network} =
          if :os.type() == {:unix, :linux} do
            {"127.0.0.1",
             ["--network=host", "-e", "PORT=#{port}", "-e", "EX_CABLE_BIND=127.0.0.1"]}
          else
            {"host.docker.internal", ["-p", "127.0.0.1:#{port}:8080"]}
          end

        args =
          ["run", "--detach", "--rm"] ++
            network ++
            [
              "--env",
              "ANYCABLE_SECRET=#{secret}",
              "--env",
              "EX_CABLE_PUBLIC_URL=http://localhost:#{port}/cable",
              "--env",
              "EX_CABLE_ALLOWED_ORIGINS=http://localhost:3000",
              "--env",
              "EX_CABLE_RPC_URL=http://#{host}:#{rails_port}/_anycable",
              image
            ]

        {output, 0} = System.cmd("docker", args)
        id = String.trim(output)
        on_exit(fn -> System.cmd("docker", ["stop", id]) end)

        assert Enum.any?(1..100, fn _ -> container_ready?(port) end),
               "Container did not become ready"
    end
  end

  defp container_ready?(port) do
    case Finch.build(:get, "http://127.0.0.1:#{port}/healthz") |> Finch.request(ExCable.Finch) do
      {:ok, %{status: 200}} ->
        true

      _ ->
        Process.sleep(100)
        false
    end
  end

  defp start_rails(port, secret) do
    ruby = System.fetch_env!("EX_CABLE_RAILS_RUBY")
    fixture = Path.expand("fixtures/rails.rb", __DIR__)

    child =
      Port.open({:spawn_executable, ruby}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 512},
        {:args, [fixture]},
        {:env,
         [
           {~c"ANYCABLE_SECRET", to_charlist(secret)},
           {~c"ANYCABLE_HTTP_BROADCAST_URL", ~c"http://127.0.0.1:#{port}/_broadcast"}
         ]}
      ])

    {child, rails_port(child, [])}
  end

  defp rails_port(child, lines) do
    receive do
      {^child, {:data, {:eol, "RAILS_PORT=" <> port}}} ->
        String.to_integer(port)

      {^child, {:data, {_, line}}} ->
        rails_port(child, [line | lines])

      {^child, {:exit_status, status}} ->
        flunk("Rails exited (#{status}): #{Enum.reverse(lines) |> Enum.join("\n")}")
    after
      5_000 -> flunk("Rails did not report its port")
    end
  end

  defp await_events(port, events, attempts \\ 50)
  defp await_events(_, events, 0), do: events

  defp await_events(port, events, attempts) do
    events = events ++ JSON.decode!(request(port, "/events").body)

    if "disconnect:42" in events do
      events
    else
      Process.sleep(20)
      await_events(port, events, attempts - 1)
    end
  end

  defp request(port, path) do
    {:ok, response} =
      Finch.build(:get, "http://127.0.0.1:#{port}" <> path) |> Finch.request(ExCable.Finch)

    response
  end
end
