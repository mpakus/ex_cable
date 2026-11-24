defmodule ExCable.HTTP do
  @behaviour Plug
  import Plug.Conn

  @protocol "actioncable-v1-json"

  def listener(config) do
    {Bandit,
     plug: {__MODULE__, config},
     ip: config.ip,
     port: config.port,
     websocket_options: [max_frame_size: 65_536, max_fragmented_message_size: 65_536],
     thousand_island_options: [transport_options: [send_timeout: 5_000]]}
  end

  @impl true
  def init(config), do: config

  @impl true
  def call(%{method: "GET", request_path: "/cable"} = conn, config) do
    url = request_url(conn, config.public_url)

    with true <- allowed_origin?(conn, url, config.origins),
         {:ok, conn} <- negotiate(conn),
         :ok <- Bandit.WebSocket.UpgradeValidation.validate_upgrade(conn) do
      env = %{
        "url" => websocket_url(url),
        "headers" => forwarded_headers(conn, config.proxy_headers)
      }

      upgrade_adapter(conn, :websocket, {ExCable.Socket, {config, env}, [timeout: 30_000]})
    else
      false -> send_resp(conn, 403, "")
      {:error, _} -> send_resp(conn, 400, "")
    end
  end

  def call(%{method: "POST", request_path: "/_broadcast"} = conn, config) do
    case config.broadcast_secret do
      secret when secret in [nil, ""] ->
        send_resp(conn, 404, "")

      secret ->
        if authorized?(conn, secret), do: read_broadcast(conn), else: send_resp(conn, 401, "")
    end
  end

  def call(%{method: "GET", request_path: "/_stats"} = conn, config) do
    cond do
      config.stats_key in [nil, ""] ->
        send_resp(conn, 404, "")

      authorized?(conn, config.stats_key) ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type("application/json")
        |> send_resp(200, JSON.encode_to_iodata!(ExCable.Stats.snapshot(config)))

      true ->
        send_resp(conn, 401, "")
    end
  end

  def call(%{method: "GET", request_path: "/healthz"} = conn, config) do
    if is_nil(config.redis_url) or ExCable.Redis.ready?(),
      do: send_resp(conn, 200, "ok"),
      else: send_resp(conn, 503, "Redis subscription unavailable")
  end

  def call(conn, _config), do: send_resp(conn, 404, "")

  defp authorized?(conn, secret) do
    case get_req_header(conn, "authorization") do
      [auth] -> Plug.Crypto.secure_compare(auth, "Bearer " <> secret)
      _ -> false
    end
  end

  defp read_broadcast(conn) do
    limit = ExCable.Broadcast.max_size()

    case read_body(conn, length: limit, read_length: limit, read_timeout: 2_000) do
      {:ok, body, conn} when byte_size(body) <= limit ->
        case ExCable.Broadcast.ingest(body) do
          :ok ->
            ExCable.Stats.increment(:http_broadcasts)
            send_resp(conn, 201, "")

          :error ->
            send_resp(conn, 422, "")
        end

      {:ok, _, conn} ->
        send_resp(conn, 413, "")

      {:more, _, conn} ->
        send_resp(conn, 413, "")

      {:error, :timeout} ->
        send_resp(conn, 408, "")

      {:error, _} ->
        send_resp(conn, 400, "")
    end
  end

  defp negotiate(conn) do
    case get_req_header(conn, "sec-websocket-protocol") do
      [] ->
        {:ok, conn}

      values ->
        if @protocol in Enum.flat_map(values, &Plug.Conn.Utils.list/1) do
          {:ok, put_resp_header(conn, "sec-websocket-protocol", @protocol)}
        else
          {:error, :subprotocol}
        end
    end
  end

  defp allowed_origin?(conn, url, origins) do
    allowed = if origins == [], do: [origin(url)], else: origins

    case get_req_header(conn, "origin") do
      [] -> true
      [origin] -> origin in allowed
      _ -> false
    end
  end

  defp origin(url) do
    uri = URI.parse(url)
    scheme = if uri.scheme in ["https", "wss"], do: "https", else: "http"
    URI.to_string(%{uri | scheme: scheme, path: nil, query: nil})
  end

  defp request_url(conn, nil), do: Plug.Conn.request_url(conn)

  defp request_url(conn, public_url) do
    uri = URI.parse(public_url)
    path = uri.path || conn.request_path
    query = if conn.query_string != "", do: conn.query_string
    URI.to_string(%{uri | path: path, query: query})
  end

  defp websocket_url(url) do
    uri = URI.parse(url)
    scheme = if uri.scheme in ["https", "wss"], do: "wss", else: "ws"
    URI.to_string(%{uri | scheme: scheme})
  end

  defp forwarded_headers(conn, names) do
    for name <- names,
        values = get_req_header(conn, name),
        values != [],
        into: %{} do
      {name, Enum.join(values, if(name == "cookie", do: "; ", else: ", "))}
    end
  end
end
