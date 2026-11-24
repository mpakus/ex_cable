defmodule ExCable.TestReplica do
  def start(config) do
    Application.load(:ex_cable)
    Application.put_env(:ex_cable, :listen, false)
    {:ok, _} = Application.ensure_all_started(:ex_cable)

    {:ok, supervisor} =
      Supervisor.start_link(
        ExCable.Redis.children(config) ++
          [Supervisor.child_spec(ExCable.HTTP.listener(config), id: Bandit)],
        strategy: :rest_for_one
      )

    Process.unlink(supervisor)

    {Bandit, bandit, :supervisor, _} =
      List.keyfind(Supervisor.which_children(supervisor), Bandit, 0)

    {:ok, {_, port}} = ThousandIsland.listener_info(bandit)
    port
  end
end
