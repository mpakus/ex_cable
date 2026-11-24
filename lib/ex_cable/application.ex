defmodule ExCable.Application do
  use Application

  @impl true
  def start(_type, _args) do
    config = ExCable.Config.from_env(Application.get_env(:ex_cable, :production, false))

    children = [
      {Registry,
       keys: :duplicate, name: ExCable.Registry, partitions: System.schedulers_online()},
      {Finch,
       name: ExCable.Finch,
       pools: %{
         default: [
           size: config.rpc_pool_size,
           conn_max_idle_time: 10_000,
           conn_opts: [transport_opts: [timeout: config.rpc_timeout]]
         ]
       }},
      {Task.Supervisor, name: ExCable.Disconnects, max_children: config.rpc_pool_size * 2}
    ]

    children =
      if Application.get_env(:ex_cable, :listen, true) do
        children ++ ExCable.Redis.children(config) ++ [ExCable.HTTP.listener(config)]
      else
        children
      end

    Supervisor.start_link(children, strategy: :rest_for_one, name: ExCable.Supervisor)
  end
end
