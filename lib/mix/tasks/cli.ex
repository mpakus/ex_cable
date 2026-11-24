defmodule Mix.Tasks.Cli do
  use Mix.Task

  @shortdoc "Displays statistics from a running ExCable server"
  @requirements ["app.config"]

  @impl true
  def run(args), do: ExCable.CLI.main(args)
end
