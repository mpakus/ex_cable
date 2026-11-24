defmodule ExCable.TestWire do
  import ExUnit.Assertions
  alias Mint.WebSocket

  def listen({ExCable.HTTP, config}) do
    {Bandit, opts} = ExCable.HTTP.listener(%{config | port: 0})
    start_listener(Keyword.put(opts, :startup_log, false))
  end

  def listen(plug) do
    start_listener(plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false)
  end

  defp start_listener(opts) do
    spec = Supervisor.child_spec({Bandit, opts}, id: make_ref())
    pid = ExUnit.Callbacks.start_supervised!(spec)
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    port
  end

  def open(port, headers, path \\ "/cable") do
    {:ok, conn} = Mint.HTTP.connect(:http, "localhost", port, mode: :passive, protocols: [:http1])
    {:ok, conn, ref} = WebSocket.upgrade(:ws, conn, path, headers)
    {conn, status, headers, data} = handshake(conn, ref, nil, [], [])
    {conn, ref, status, headers, data}
  end

  def connect(
        port,
        headers \\ [{"sec-websocket-protocol", "actioncable-v1-json"}],
        path \\ "/cable"
      ) do
    {conn, ref, 101, headers, data} = open(port, headers, path)
    assert {"sec-websocket-protocol", "actioncable-v1-json"} in headers
    {:ok, conn, ws} = WebSocket.new(conn, ref, 101, headers)
    {:ok, ws, frames} = WebSocket.decode(ws, IO.iodata_to_binary(data))
    %{conn: conn, ws: ws, ref: ref, frames: frames}
  end

  def send_frame(client, frame) do
    {:ok, ws, data} = WebSocket.encode(client.ws, frame)
    {:ok, conn} = WebSocket.stream_request_body(client.conn, client.ref, data)
    %{client | ws: ws, conn: conn}
  end

  def command(client, command, id, extra \\ %{}) do
    body = Map.merge(%{"command" => command, "identifier" => id}, extra)
    send_frame(client, {:text, JSON.encode!(body)})
  end

  def next(client) do
    case client.frames do
      [frame | rest] ->
        {frame, %{client | frames: rest}}

      [] ->
        {:ok, conn, replies} = WebSocket.recv(client.conn, 0, 1500)
        data = for {:data, _, chunk} <- replies, do: chunk
        {:ok, ws, frames} = WebSocket.decode(client.ws, IO.iodata_to_binary(data))
        next(%{client | conn: conn, ws: ws, frames: frames})
    end
  end

  def json(client) do
    case next(client) do
      {{:text, data}, client} -> {JSON.decode!(data), client}
      {{:ping, data}, client} -> client |> send_frame({:pong, data}) |> json()
    end
  end

  def event(client) do
    case json(client) do
      {%{"type" => "ping"}, client} -> event(client)
      result -> result
    end
  end

  def close(client), do: Mint.HTTP.close(client.conn)

  defp handshake(conn, ref, status, headers, data) do
    {:ok, conn, replies} = WebSocket.recv(conn, 0, 1500)

    {status, headers, data, done?} =
      Enum.reduce(replies, {status, headers, data, false}, fn
        {:status, ^ref, status}, {_, headers, data, done?} ->
          {status, headers, data, done?}

        {:headers, ^ref, headers}, {status, _, data, done?} ->
          {status, headers, data, done?}

        {:data, ^ref, chunk}, {status, headers, data, done?} ->
          {status, headers, [data, chunk], done?}

        {:done, ^ref}, {status, headers, data, _} ->
          {status, headers, data, true}
      end)

    if done?, do: {conn, status, headers, data}, else: handshake(conn, ref, status, headers, data)
  end
end

defmodule ExCable.TestRPC do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, handler) do
    {:ok, body, conn} = read_body(conn)

    {status, response} =
      handler.(conn.request_path, JSON.decode!(body), Map.new(conn.req_headers))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(response))
  end
end
