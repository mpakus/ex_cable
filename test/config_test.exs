defmodule ExCable.ConfigTest do
  use ExUnit.Case, async: true
  alias ExCable.Config

  test "derives the Cabby-compatible broadcast HMAC and uses explicit overrides" do
    config = Config.from_env(false, &if(&1 == "ANYCABLE_SECRET", do: "qwerty"))

    assert config.broadcast_secret ==
             "42923a28b760e667fc92f7c6123bb07a282822b329dd2ef48e7aee7830d98485"

    refute config.broadcast_secret == config.rpc_secret

    env = %{
      "ANYCABLE_SECRET" => "qwerty",
      "ANYCABLE_BROADCAST_KEY" => "broadcast",
      "ANYCABLE_HTTP_RPC_SECRET" => "rpc",
      "EX_CABLE_RPC_URL" => "https://rails.example/_anycable/",
      "EX_CABLE_ALLOWED_ORIGINS" => "https://one.example, https://two.example"
    }

    config = Config.from_env(true, &env[&1])
    assert config.broadcast_secret == "broadcast"
    assert config.rpc_secret == "rpc"
    assert config.rpc_url == "https://rails.example/_anycable"
    assert config.origins == ["https://one.example", "https://two.example"]
  end

  test "validates bind addresses, port ranges and URL schemes" do
    values = %{"EX_CABLE_BIND" => "0.0.0.0", "PORT" => "9080", "EX_CABLE_RPC_POOL_SIZE" => "32"}
    config = Config.from_env(false, &values[&1])
    assert config.ip == {0, 0, 0, 0}
    assert config.port == 9080
    assert config.rpc_pool_size == 32

    for {name, value, error} <- [
          {"PORT", "65536", "Expected an integer between 1 and 65535"},
          {"EX_CABLE_BIND", "localhost", "EX_CABLE_BIND must be an IP address"},
          {"EX_CABLE_RPC_URL", "ftp://rails.example", "Invalid URL scheme"}
        ] do
      assert_raise RuntimeError, error, fn ->
        Config.from_env(false, &if(&1 == name, do: value))
      end
    end
  end

  test "rejects incomplete production settings and malformed URLs" do
    assert_raise RuntimeError, "A Rails RPC secret is required", fn ->
      Config.from_env(true, fn _ -> nil end)
    end

    assert_raise RuntimeError, "A public URL or explicit allowed origins are required", fn ->
      Config.from_env(true, &if(&1 == "ANYCABLE_SECRET", do: "fixture"))
    end

    assert_raise RuntimeError,
                 "Expected an absolute URL without credentials, a query or a fragment",
                 fn ->
                   Config.from_env(
                     false,
                     &if(&1 == "EX_CABLE_RPC_URL", do: "https://user:secret@rails.example")
                   )
                 end
  end
end
