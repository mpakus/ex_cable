defmodule ExCable.Config do
  def defaults do
    %{
      ip: {127, 0, 0, 1},
      port: 8080,
      rpc_url: "http://127.0.0.1:3000/_anycable",
      rpc_secret: nil,
      rpc_pool_size: 16,
      rpc_timeout: 2_000,
      broadcast_secret: nil,
      public_url: nil,
      origins: [],
      proxy_headers: ~w(cookie origin authorization x-request-id),
      heartbeat: 3_000,
      redis_url: nil,
      redis_channel: "__anycable__"
    }
  end

  def from_env(production?, get \\ &System.get_env/1) do
    config = defaults()
    secret = get.("ANYCABLE_SECRET")

    config = %{
      config
      | ip: parse_ip(get.("EX_CABLE_BIND") || "127.0.0.1"),
        port: integer(get.("PORT"), config.port, 65_535),
        rpc_url: url(get.("EX_CABLE_RPC_URL") || config.rpc_url, ["http", "https"]),
        rpc_secret: get.("ANYCABLE_HTTP_RPC_SECRET") || derive(secret, "rpc-cable"),
        rpc_pool_size: integer(get.("EX_CABLE_RPC_POOL_SIZE"), config.rpc_pool_size, 1_024),
        rpc_timeout: integer(get.("EX_CABLE_RPC_TIMEOUT_MS"), config.rpc_timeout, 30_000),
        broadcast_secret:
          get.("ANYCABLE_BROADCAST_KEY") || get.("ANYCABLE_HTTP_BROADCAST_SECRET") ||
            derive(secret, "broadcast-cable"),
        public_url: url(get.("EX_CABLE_PUBLIC_URL"), ["http", "https", "ws", "wss"]),
        origins: split(get.("EX_CABLE_ALLOWED_ORIGINS"), []),
        proxy_headers: split(get.("EX_CABLE_PROXY_HEADERS"), config.proxy_headers),
        redis_url: get.("ANYCABLE_REDIS_URL"),
        redis_channel: get.("ANYCABLE_REDIS_CHANNEL") || config.redis_channel
    }

    if production? and config.rpc_secret in [nil, ""], do: raise("A Rails RPC secret is required")

    if production? and is_nil(config.public_url) and config.origins == [],
      do: raise("A public URL or explicit allowed origins are required")

    config
  end

  defp derive(secret, purpose) when is_binary(secret) and secret != "",
    do: :hmac |> :crypto.mac(:sha256, secret, purpose) |> Base.encode16(case: :lower)

  defp derive(_, _), do: nil

  defp url(nil, _), do: nil

  defp url(value, schemes) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host, query: nil, fragment: nil, userinfo: nil}}
      when is_binary(host) and host != "" ->
        if scheme in schemes,
          do: String.trim_trailing(value, "/"),
          else: raise("Invalid URL scheme")

      _ ->
        raise "Expected an absolute URL without credentials, a query or a fragment"
    end
  end

  defp split(nil, defaults), do: defaults

  defp split(values, _),
    do: values |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp integer(nil, default, _), do: default

  defp integer(value, _, max) do
    case Integer.parse(value) do
      {number, ""} when number >= 1 and number <= max -> number
      _ -> raise "Expected an integer between 1 and #{max}"
    end
  end

  defp parse_ip(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, address} -> address
      {:error, _} -> raise "EX_CABLE_BIND must be an IP address"
    end
  end
end
