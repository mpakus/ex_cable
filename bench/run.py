#!/usr/bin/env python3
"""Run the same Action Cable load against each server and record per-process RSS."""

import argparse
import csv
import json
import os
import platform
import resource
import signal
import socket
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parent.parent
KEY = "local-comparative-benchmark"
SERVERS = ("excable", "cabby", "actioncable")


def now():
    return datetime.now(timezone.utc).isoformat()


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def isolated_env():
    prefixes = ("ANYCABLE_", "EX_CABLE_", "RELEASE_", "PUMA_", "RAILS_")
    return {key: value for key, value in os.environ.items() if not key.startswith(prefixes)}


def start(stack, argv, env, log, stdout=None):
    sink = stack.enter_context(log.open("w"))
    process = subprocess.Popen(argv, cwd=ROOT, env=env, stdout=stdout or sink, stderr=sink,
                               start_new_session=True)
    stack.callback(stop, process)
    return process


def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def await_ready(process, port, path):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"process {process.pid} exited with {process.returncode} during startup")
        try:
            with urlopen(f"http://127.0.0.1:{port}{path}", timeout=0.5) as response:
                if response.status == 200:
                    return
        except OSError:
            time.sleep(0.1)
    raise TimeoutError(f"process {process.pid} did not become ready")


def start_rails(stack, args, port, mode, log):
    env = isolated_env() | {
        "PORT": str(port),
        "RAILS_ENV": "production",
        "BENCH_MODE": mode,
        "ANYCABLE_HTTP_RPC": "true",
        "ANYCABLE_HTTP_RPC_SECRET": KEY,
        "ANYCABLE_BROADCAST_KEY": KEY,
    }
    process = start(stack, [args.ruby, "--yjit", "bench/fixture.rb"], env, log)
    await_ready(process, port, "/healthz")
    return process


def excable_command(args, out, env):
    if not args.beam_probe:
        return [args.excable, "start"]
    root = Path(args.excable).resolve().parent.parent
    _, version = (root / "releases/start_erl.data").read_text().split()
    release = root / "releases" / version
    env["BENCH_MEMORY_DIR"] = str(out)
    return [
        str(release / "elixir"), "--erl", "-mode embedded", "--erl-config", str(release / "sys"),
        "--boot", str(release / "start"), "--boot-var", "RELEASE_LIB", str(root / "lib"),
        "--vm-args", str(release / "vm.args"), "-pa", str(args.beam_probe.resolve()), "--no-halt",
        "--eval", ('{:module, ExCable.BenchMemory} = :code.load_file(ExCable.BenchMemory); '
                   'ExCable.BenchMemory.start(System.fetch_env!("BENCH_MEMORY_DIR"))'),
    ]


def subject(stack, args, name, out):
    host = "127.0.0.1"
    port = free_port()
    if name == "actioncable":
        return start_rails(stack, args, port, "native", out / "server.log"), None, port
    rails_port = free_port()
    rails = start_rails(stack, args, rails_port, "rpc", out / "rails.log")
    rpc_url = f"http://{host}:{rails_port}/_anycable"
    env = isolated_env()
    if name == "excable":
        env |= {
            "PORT": str(port),
            "EX_CABLE_PUBLIC_URL": f"http://{host}:{port}/cable",
            "EX_CABLE_RPC_URL": rpc_url,
            "EX_CABLE_RPC_POOL_SIZE": "16",
            "ANYCABLE_HTTP_RPC_SECRET": KEY,
            "ANYCABLE_BROADCAST_KEY": KEY,
            "RELEASE_DISTRIBUTION": "none",
        }
        argv = excable_command(args, out, env)
        health = "/healthz"
    else:
        env["ANYCABLE_DISABLE_TELEMETRY"] = "true"
        argv = [args.cabby, f"--host={host}", f"--port={port}", f"--rpc_host={rpc_url}",
                "--rpc_impl=http", "--rpc_concurrency=16", f"--http_rpc_secret={KEY}",
                f"--broadcast_key={KEY}", f"--http_broadcast_port={port}", "--broadcast_adapter=http",
                "--broker=none", "--pubsub=none", "--streams_presence=false", "--metrics_http=/metrics",
                "--log_level=error", "--disconnect_mode=always", "--ping_interval=3"]
        health = "/metrics"
    server = start(stack, argv, env, out / "server.log")
    await_ready(server, port, health)
    return server, rails, port


def rss(server, rails):
    pids = [str(server.pid)] + ([str(rails.pid)] if rails else [])
    command = ["ps", "-o", "pid=,rss=", "-p", ",".join(pids)]
    rows = subprocess.check_output(command, text=True).splitlines()
    rss_by_pid = {int(pid): int(kib) for pid, kib in (row.split() for row in rows)}
    return rss_by_pid[server.pid], rss_by_pid[rails.pid] if rails else 0


def run_one(args, name, rate, repeat):
    out = args.out / args.scenario / f"{rate:03d}-{repeat}-{name}"
    out.mkdir(parents=True, exist_ok=False)
    print(f"{now()} {args.scenario} {name} rate={rate} repeat={repeat} starting", flush=True)
    if args.scenario == "soak":
        workload = ["-clients=240", "-rooms=12", "-warmup=60s", "-duration=" + args.soak_duration,
                    "-lifetime-min=15s", "-lifetime-max=35s", "-drain=10s"]
        interval, settle = 5, 30
    elif args.scenario == "smoke":
        workload = ["-clients=12", "-rooms=3", "-warmup=2s", "-duration=6s",
                    "-lifetime-min=1500ms", "-lifetime-max=3500ms", "-idle=1s", "-drain=2s"]
        interval, settle = 0.5, 2
    else:
        workload = ["-clients=240", "-rooms=1", "-warmup=4s", "-duration=15s", "-drain=5s"]
        interval, settle = 1, 5

    with ExitStack() as stack:
        server, rails, port = subject(stack, args, name, out)
        time.sleep(1)
        if name == "excable" and args.beam_probe and not (out / "beam.jsonl").exists():
            raise RuntimeError(f"{out}: BEAM memory probe failed during startup")
        summary = stack.enter_context((out / "load.json").open("w"))
        csv_file = stack.enter_context((out / "rss.csv").open("w", newline=""))
        writer = csv.writer(csv_file)
        writer.writerow(("timestamp_utc", "phase", "server_kib", "rails_rpc_kib", "combined_kib"))

        def sample(phase):
            first, second = rss(server, rails)
            writer.writerow((now(), phase, first, second, first + second))
            csv_file.flush()

        sample("baseline")
        argv = [args.driver, f"-url=http://127.0.0.1:{port}", f"-key={KEY}", f"-rate={rate}", *workload]
        proc = start(stack, argv, isolated_env(), out / "load.log", stdout=summary)
        while proc.poll() is None:
            sample("load")
            time.sleep(interval)
        if proc.returncode != 0:
            raise RuntimeError(f"{name} driver exited with status {proc.returncode}. See {out / 'load.log'}")

        deadline = time.monotonic() + settle
        while time.monotonic() < deadline:
            sample("settling")
            time.sleep(interval)
        sample("residual")
        if name == "excable" and args.beam_probe:
            (out / "collect").touch()
            deadline = time.monotonic() + 12
            while not (out / "collected").exists():
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"{out}: no BEAM memory probe response")
                time.sleep(0.1)
            time.sleep(1)
            sample("post_major_gc")
            (out / "collect").unlink()
            (out / "collected").unlink()
    result = json.loads((out / "load.json").read_text())
    print(f"{now()} {args.scenario} {name} rate={rate} repeat={repeat} "
          f"{result['unique_deliveries']}/{result['expected_deliveries']} delivered, "
          f"{result['reconnects_completed']} reconnects", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scenario", choices=("smoke", "steady", "soak"))
    parser.add_argument("--driver", required=True)
    parser.add_argument("--cabby")
    parser.add_argument("--ruby", required=True)
    parser.add_argument("--excable", default=str(ROOT / "_build/prod/rel/ex_cable/bin/ex_cable"))
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--servers", nargs="+", choices=SERVERS, default=SERVERS)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--soak-duration", default="20m")
    parser.add_argument("--beam-probe", type=Path, help="Directory with the compiled BEAM memory probe")
    args = parser.parse_args()
    if "cabby" in args.servers and not args.cabby:
        parser.error("--cabby is required when benchmarking Cabby")
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    if soft < 4096:
        resource.setrlimit(resource.RLIMIT_NOFILE, (4096 if hard < 0 else min(hard, 4096), hard))
    print(f"{platform.platform()} logical_cpus={os.cpu_count()} fd_limit={resource.getrlimit(resource.RLIMIT_NOFILE)[0]}",
          flush=True)

    if args.scenario == "soak":
        with ThreadPoolExecutor(max_workers=len(args.servers)) as pool:
            tasks = [pool.submit(run_one, args, name, 72, 1) for name in args.servers]
            for task in tasks:
                task.result()
    else:
        rates = (50, 150) if args.scenario == "steady" else (12,)
        order = list(args.servers)
        for i in range(args.rounds if args.scenario == "steady" else 1):
            for j, rate in enumerate(rates):
                for k in range(len(order)):
                    run_one(args, order[(i + j + k) % len(order)], rate, i + 1)


if __name__ == "__main__":
    main()
