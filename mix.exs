defmodule ExCable.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_cable,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [ignore_modules: [ExCable.TestReplica, ExCable.TestRPC, ExCable.TestWire]],
      deps: [
        {:bandit, "~> 1.15.0"},
        {:finch, "~> 0.25.0"},
        {:redix, "~> 1.10.0"},
        {:mint_web_socket, "~> 1.0", only: :test}
      ]
    ]
  end

  def application do
    [mod: {ExCable.Application, []}, extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
