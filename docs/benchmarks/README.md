# ExCable, Cabby and Action Cable benchmark

See the [November 24 capacity sweep](capacity.md) for the newer HTTP ingress and fan-out measurements.

All three servers sustained 36,000 deliveries/s with zero missing deliveries in
the highest steady workload. Cabby had the smallest gateway RSS. During the soak, all
three delivered roughly 1,411 eligible events/s and completed every planned reconnect.
ExCable's RSS rose during churn.

## Steady fan-out

Throughput and latency are medians of three 15-second trials per row. Loss counts are
summed. All 18 trials completed with zero publication errors, duplicates, misroutes,
unexpected disconnects and reconnects. At 36,000 deliveries/s, the worst per-trial
publisher scheduling p99 was 1.07 ms.

| Server | Publications/s | Delivered/s | Delivery p95 / p99 (ms) | Missing / expected |
| --- | ---: | ---: | ---: | ---: |
| ExCable | 50 | 12,000 | 5.20 / 6.56 | 0 / 540,000 |
| Cabby | 50 | 12,000 | 5.39 / 7.65 | 0 / 540,000 |
| Action Cable | 50 | 12,000 | 6.15 / 7.27 | 0 / 540,000 |
| ExCable | 150 | 36,000 | 2.87 / 3.80 | 0 / 1,620,000 |
| Cabby | 150 | 36,000 | 2.90 / 4.11 | 0 / 1,620,000 |
| Action Cable | 150 | 36,000 | 4.20 / 4.85 | 0 / 1,620,000 |

RSS values are per-trial medians in MiB. Idle is the sample median during the
connected, pre-publication period. Peak covers connected idle, warmup, measurement
and drain. Residual is sampled five seconds after the load driver exits.

| Server | Publications/s | Primary RSS cold / idle / peak / residual | Combined RSS cold / idle / peak / residual |
| --- | ---: | ---: | ---: |
| ExCable | 50 | 173.7 / 180.0 / 183.6 / 174.6 | 245.2 / 256.8 / 260.4 / 251.8 |
| Cabby | 50 | 12.2 / 18.2 / 19.0 / 19.4 | 84.6 / 98.1 / 99.0 / 100.0 |
| Action Cable | 50 | 65.4 / 82.2 / 89.1 / 89.9 | 65.4 / 82.2 / 89.1 / 89.9 |
| ExCable | 150 | 175.5 / 183.7 / 186.9 / 177.8 | 247.1 / 263.9 / 267.5 / 258.7 |
| Cabby | 150 | 12.2 / 18.1 / 18.9 / 19.7 | 84.0 / 97.7 / 98.9 / 100.0 |
| Action Cable | 150 | 65.4 / 81.9 / 89.5 / 90.4 | 65.4 / 81.9 / 89.5 / 90.4 |

## Twenty-minute churn soak

Run on November 23, 2026, America/Chicago. Each subject accepted all 86,400 measured
publications. The totals account for changes in the confirmed subscriber set as clients
reconnected. All three reported zero duplicates, misroutes, failed publication requests,
failed connection attempts and incomplete reconnects.

| Server | Delivered/s | Delivery p95 / p99 (ms) | Missing / expected | Planned reconnects completed | Unexpected disconnects | Reconnect p95 / p99 (ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| ExCable | 1,411.17 | 1.57 / 2.61 | 0 / 1,693,410 | 11,449 | 0 | 105.87 / 107.57 |
| Cabby | 1,411.21 | 0.84 / 1.51 | 0 / 1,693,456 | 11,449 | 0 | 105.22 / 106.70 |
| Action Cable | 1,411.26 | 3.32 / 4.85 | 0 / 1,693,513 | 11,449 | 0 | 105.11 / 106.81 |

`RSS` is in MiB. First and last are the medians of the first and last minute of the
measured window. Peak covers connected idle, warmup, measurement and drain. Residual is
sampled 30 seconds after the load driver exits.

| Server | Primary RSS cold / first / last / peak / residual | Combined RSS cold / first / last / peak / residual |
| --- | ---: | ---: |
| ExCable | 177.6 / 184.5 / 203.0 / 205.6 / 193.5 | 250.1 / 262.4 / 282.3 / 284.3 / 273.2 |
| Cabby | 12.3 / 19.5 / 19.7 / 19.7 / 18.4 | 84.3 / 100.4 / 100.9 / 100.9 / 99.7 |
| Action Cable | 65.8 / 94.6 / 95.7 / 96.3 / 97.3 | 65.8 / 94.6 / 95.7 / 96.3 / 97.3 |

ExCable's primary-process RSS rose by 18.4 MiB between the first and last minute medians.
Cabby and native Action Cable rose by 0.2 and 1.1 MiB, respectively. The sample establishes
an RSS trend for this run. The [BEAM memory investigation](beam-memory.md) measures the allocator and process heaps
and compares the Darwin release tuning.

## Workload and method

A shared Go driver makes the workload portable to macOS, where Cabby's Linux benchmark runner
uses `/proc` for listener discovery and RSS. The Go client opens standard `actioncable-v1-json` WebSockets with a fixture cookie,
waits for subscription confirmation, and publishes timestamped JSON with a unique sequence
number through one persistent HTTP connection. The Rails fixture uses the same connection
and channel code for all three subjects. ExCable and Cabby call it through authenticated
AnyCable HTTP RPC. Native Action Cable runs the callbacks in-process and uses its async
subscription adapter. All three accept the same broadcast body and use a local broker path.

| Setting | Steady fan-out | Churn soak |
| --- | --- | --- |
| WebSocket clients | 240 | 240 per server |
| Rooms | 1 | 12, with 20 clients per room before churn |
| Publication rate | 50 and 150/s | 72/s in round-robin room order |
| Pre-run | 4 s connected idle, 4 s publishing warmup | 4 s connected idle, 60 s publishing warmup |
| Measured interval | 15 s | 20 min |
| End of run | 5 s drain and 5 s RSS settling | 10 s drain and 30 s RSS settling |
| Client churn | Reconnects only after an unexpected close | Seeded 15–35 s connection lifetimes, abrupt TCP close, 100 ms delay before reconnect |
| Scheduling | Three trials per rate and server, run serially with rotated server order | One run per server, all three run concurrently on the same host |

Throughput counts unique, eligible deliveries received before the measurement window ends.
The p95 and p99 delivery latencies include frames that arrive during the drain. The clock
starts just before the Go driver creates and sends the publication request, and ends when the
client decodes the corresponding WebSocket frame. Latency percentiles describe delivered
frames. Loss includes accepted publications that fail to arrive for an eligible subscriber
by the end of the drain. The driver excludes a 200 ms boundary at each end of a confirmed
subscription interval from eligibility. Offline intervals have no delivery expectation.
The driver counts invalid and misrouted frames, duplicates, and late arrivals separately.
Publisher scheduling lag records the difference between a scheduled POST and its actual start.

A reconnect completes when the replacement socket receives its subscription confirmation.
Reconnect latency includes the client's 100 ms delay before its first attempt. Planned
disconnects are initiated by the driver's lifetime timer. An unexpected disconnect comes
from a socket or protocol close before that timer fires. These figures cover socket recovery
while the server process stays up.

RSS is sampled from macOS `ps` at 1 s intervals for steady trials and 5 s intervals for
the soak. Gateway or native RSS is the primary server process. Combined RSS includes the
dedicated Rails RPC process for ExCable and Cabby. Process RSS can count shared pages more
than once, and sampled peaks can miss shorter spikes. The critical steady comparisons use
separate trials. The soak servers and their separate drivers share the host without CPU affinity.

## Environment

- Apple M4 Max, 16 physical/logical CPUs, 64 GiB RAM, arm64 macOS 27.2.1 (26B131).
- ExCable 0.1.0 production release, Elixir 1.19.5 and Erlang/OTP 28 (ERTS 16.4). Finch HTTP pool size 16.
- Cabby 0.1.0 from the repository checkout at `7b97ba1794639906bc9d37c3f645456ad224ec43`.
  Rust 1.100.0 release build, `--locked --no-default-features`. HTTP RPC concurrency 16.
- Rails Action Cable and Railties 8.1.1, AnyCable Rails Core 1.6.2 with Core 1.6.4, Puma 7.1.0
  in single-process mode with five request threads. Ruby 4.0.1 with YJIT enabled.
- Go 1.25.0 driver, Gorilla WebSocket 1.5.3. Local TCP only, HTTP ingress, no TLS, no external
  broker, no database or application rendering. The native Action Cable worker pool uses the
  Rails default.

This is a loopback workload with a small application fixture. The soak is a 20-minute churn
test, so its RSS trend describes this run. Server capacity and long-term memory stability can
differ under a production workload.

## Reproduce

Run these commands from the ExCable repository. The Cabby source lives in `examples/cabby`.
Set `CABBY_BIN` to the resulting Cabby executable, `BENCH_RUBY` to the Ruby executable,
and `BENCH_DRIVER` to the Go output path. Install the fixture gems into that Ruby's gem path.

```sh
rtk proxy gem install anycable-rails-core:1.6.2 actioncable:8.1.1 railties:8.1.1 puma:7.1.0
rtk proxy env MIX_ENV=prod mix release
rtk proxy rustup toolchain install 1.100.0 --profile minimal
RUSTC="$(rtk proxy rustup which --toolchain 1.100.0 rustc)" \
  rtk proxy rustup run 1.100.0 cargo build --manifest-path examples/cabby/Cargo.toml \
  --locked --release -p cabby-server --bin cabby --no-default-features
rtk proxy go -C bench test .
rtk proxy go -C bench build -o "$BENCH_DRIVER" .
rtk proxy python3 bench/run.py soak --soak-duration 20m --driver "$BENCH_DRIVER" \
  --cabby "$CABBY_BIN" --ruby "$BENCH_RUBY" --out /tmp/excable-benchmark
rtk proxy python3 bench/run.py steady --rounds 3 --driver "$BENCH_DRIVER" \
  --cabby "$CABBY_BIN" --ruby "$BENCH_RUBY" --out /tmp/excable-benchmark
```

The per-trial [raw data](raw/) contains `load.json` with counts and percentiles, `rss.csv` with
RSS samples, and the corresponding process logs. Sample timestamps are in UTC.
