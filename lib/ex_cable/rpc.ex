defmodule ExCable.RPC do
  require Logger

  def connect(config, sid, env), do: request(config, sid, "connect", %{"env" => env})

  def disconnect(config, sid, identifiers, env, subscriptions) do
    payload = %{"env" => env, "identifiers" => identifiers, "subscriptions" => subscriptions}

    notify = fn ->
      unless match?({:ok, %{"status" => 1}}, request(config, sid, "disconnect", payload)) do
        Logger.warning("Rails disconnect RPC failed")
      end
    end

    case Task.Supervisor.start_child(ExCable.Disconnects, notify) do
      {:ok, _} -> :ok
      {:error, :max_children} -> notify.()
    end
  end

  def request(config, sid, action, payload) do
    headers = [
      {"content-type", "application/json"},
      {"x-anycable-meta-sid", sid},
      {"x-anycable-meta-protov", "v1"}
    ]

    headers =
      if config.rpc_secret in [nil, ""],
        do: headers,
        else: [{"authorization", "Bearer " <> config.rpc_secret} | headers]

    body = payload |> Enum.reject(fn {_, value} -> value in ["", [], %{}] end) |> Map.new()

    request =
      Finch.build(:post, config.rpc_url <> "/" <> action, headers, JSON.encode_to_iodata!(body))

    case send_request(request, config.rpc_timeout) do
      {:ok, %{status: 200, body: body}} ->
        case JSON.decode(body) do
          {:ok, %{} = reply} -> {:ok, reply}
          _ -> {:error, :invalid_response}
        end

      {:ok, %{status: 401}} ->
        {:error, :rpc_authentication}

      {:ok, %{status: _}} ->
        {:error, :rpc_http}

      {:error, _} ->
        {:error, :rpc_unavailable}
    end
  end

  defp send_request(request, timeout) do
    Finch.request(request, ExCable.Finch,
      pool_timeout: timeout,
      receive_timeout: timeout,
      request_timeout: timeout
    )
  rescue
    error in RuntimeError ->
      case error do
        %RuntimeError{message: "Finch was unable to provide a connection" <> _} ->
          {:error, :pool_timeout}

        _ ->
          reraise error, __STACKTRACE__
      end
  end
end
