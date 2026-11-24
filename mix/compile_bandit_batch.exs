defmodule Mix.Tasks.Compile.BanditBatch do
  use Mix.Task.Compiler

  @moduledoc false
  @patch Path.join(__DIR__, "bandit-1.15.0.patch")
  @module Bandit.WebSocket.Connection

  # Compile only the patched module into this environment's Bandit build.
  # The Hex checkout stays pristine, including when MIX_DEPS_PATH is shared.
  @impl true
  def run(_) do
    source = Path.join(Mix.Project.deps_paths().bandit, "lib/bandit/websocket/connection.ex")
    beam = Path.join([Mix.Project.build_path(), "lib/bandit/ebin", "#{@module}.beam"])
    directory = Mix.Project.manifest_path()
    manifest = Path.join(directory, "compile.bandit_batch")
    inputs = [File.read!(source), File.read!(@patch)]

    if File.read(manifest) == {:ok, :crypto.hash(:sha256, [inputs, File.read!(beam)])} do
      {:noop, []}
    else
      File.mkdir_p!(directory)
      patched = Path.join(directory, "bandit_connection.ex")

      case System.cmd("patch", ["-s", "-f", "-F", "0", "-o", patched, source, @patch],
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {message, _} -> Mix.raise("Could not apply the Bandit 1.15.0 write patch: #{message}")
      end

      previous = Code.compiler_options(ignore_module_conflict: true)

      try do
        [{@module, binary}] = Code.compile_file(patched)
        File.write!(beam <> ".tmp", binary)
        File.rename!(beam <> ".tmp", beam)
        File.write!(manifest, :crypto.hash(:sha256, [inputs, binary]))
      after
        Code.compiler_options(previous)
      end

      {:ok, []}
    end
  end
end
