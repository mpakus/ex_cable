# ExCable

ExCable is a small Elixir server for Rails Action Cable WebSockets. It speaks
`actioncable-v1-json` and delegates authentication and channel callbacks to the Rails
application over AnyCable HTTP RPC. Existing `@rails/actioncable` clients and compatible Rails
channels use the same messages and identifiers.

Bandit runs one BEAM process per socket. Each process owns its connection and subscription state.
A partitioned OTP Registry routes broadcasts directly to local sockets. Redis Pub/Sub distributes
Rails broadcasts and remote disconnects across instances.

```mermaid
flowchart LR
    Client["Action Cable client"] <-->|"WebSocket /cable"| Cable["ExCable"]
    Cable -->|"HTTP RPC"| Rails["Rails + anycable-rails-core"]
    Rails -->|"POST /_broadcast · single instance"| Cable
    Rails -->|"PUBLISH · multiple instances"| Redis["Redis / Valkey"]
    Redis -->|"Pub/Sub"| Cable
```

## Run with Rails

Use Elixir 1.19 and Erlang/OTP 28. Install the Elixir dependencies.

```sh
rtk proxy mix deps.get
```

Add `gem "anycable-rails-core", require: "anycable/rails"` to the Rails Gemfile and install it
with Bundler. Set `adapter: any_cable` in `config/cable.yml` for the active Rails environment.
Start Rails with these environment variables. Set `ANYCABLE_SECRET` to the same random value
for Rails and ExCable.

```sh
export ANYCABLE_HTTP_RPC=true
export ANYCABLE_BROADCAST_ADAPTER=http
export ANYCABLE_HTTP_BROADCAST_URL=http://localhost:8080/_broadcast
export ANYCABLE_WEBSOCKET_URL=ws://localhost:8080/cable
bin/rails server
```

Start ExCable in its own terminal.

```sh
export EX_CABLE_RPC_URL=http://127.0.0.1:3000/_anycable
export EX_CABLE_PUBLIC_URL=http://localhost:8080/cable
export EX_CABLE_ALLOWED_ORIGINS=http://localhost:3000
rtk proxy mix run --no-halt
```

Point any explicit `createConsumer(url)` calls at `ws://localhost:8080/cable`. Keep the Rails
origin allowlist aligned with ExCable's if your Rails app overrides it. In production, route
WebSocket upgrades through your TLS proxy and keep RPC endpoints and broker traffic private.
[Action Cable configuration](https://guides.rubyonrails.org/action_cable_overview.html#configuration) · [AnyCable HTTP RPC](https://docs.anycable.io/ruby/http_rpc)

### Run multiple instances

On Rails, install the `redis` gem and set `ANYCABLE_BROADCAST_ADAPTER=redis`. Set
`ANYCABLE_REDIS_URL` and the same `ANYCABLE_REDIS_CHANNEL` on Rails and every ExCable instance.
Route `/cable` through the load balancer. `GET /healthz` reports `503` while the configured
Redis subscription is unavailable. Redis Pub/Sub provides live delivery with no replay.
[Redis adapter configuration](https://docs.anycable.io/ruby/broadcast_adapters#redis-pub-sub)

### Configuration

| Environment variable | Default or behavior |
| --- | --- |
| `EX_CABLE_BIND` | `127.0.0.1`. Set an explicit interface for containers or remote proxies. |
| `PORT` | `8080` |
| `EX_CABLE_RPC_URL` | `http://127.0.0.1:3000/_anycable` |
| `ANYCABLE_SECRET` | Derives separate bearer keys for RPC and HTTP broadcasts. |
| `ANYCABLE_HTTP_RPC_SECRET` | Overrides the derived RPC key. |
| `ANYCABLE_BROADCAST_KEY` | Overrides the derived broadcast key. Without a key, `/_broadcast` is disabled. |
| `EX_CABLE_STATS_KEY` | Enables the statistics endpoint and authenticates the CLI. Set it on the server and in the CLI environment. |
| `EX_CABLE_PUBLIC_URL` | External cable URL. Without it, ExCable uses the upgrade's request URL. |
| `EX_CABLE_ALLOWED_ORIGINS` | Comma-separated exact browser origins. Defaults to the cable URL's HTTP origin. |
| `EX_CABLE_PROXY_HEADERS` | Comma-separated lowercase names. Defaults to `cookie,origin,authorization,x-request-id`. |
| `EX_CABLE_RPC_POOL_SIZE` | `16` HTTP connections per RPC origin. Set according to Rails capacity. |
| `EX_CABLE_RPC_TIMEOUT_MS` | `2000` per pool checkout, connect or request timeout. |
| `ANYCABLE_REDIS_URL` | Enables Redis Pub/Sub. Supports `redis://` or `rediss://`. |
| `ANYCABLE_REDIS_CHANNEL` | `__anycable__` |

A production release requires an RPC secret and either the public cable URL or an explicit
origin list. Build and run it with those settings in the environment.

```sh
MIX_ENV=prod rtk proxy mix release
rtk proxy _build/prod/rel/ex_cable/bin/ex_cable start
```

## Statistics CLI

Set `EX_CABLE_STATS_KEY` before starting ExCable and use the same key in the terminal
that runs the CLI. The CLI defaults to `http://127.0.0.1:8080`. Use `--url BASE_URL`
for a different address or HTTPS when connecting across hosts.

```sh
rtk proxy mix cli                            # Print one snapshot from a running server
rtk proxy _build/prod/rel/ex_cable/bin/cli -f  # Refresh in place until Ctrl+C
ELIXIR_ERL_OPTIONS="+Bd" rtk proxy mix cli -f # Follow from a source checkout
```

The table shows active authenticated WebSockets, stream memberships, accepted broadcast
POSTs, stream publications from HTTP or Redis, slow consumers flagged for disconnect,
BEAM memory and processes, and Redis subscription status. Counters are per instance and
reset when ExCable starts. The first table shows rates since startup. Follow mode then
shows rates between successful samples, refreshing about once per second.

## Benchmark results

Loopback on an Apple M4 Max. Each row reports the median of three runs at the same load.
The [full sweep](docs/benchmarks/capacity.md) covers 8–256 HTTP publishers and fan-out loads
from 200 to 8,000 offered POSTs/s.

**Cabby led on throughput. ExCable had the lowest WebSocket delivery p99 under saturation.**

- **HTTP without subscribers.** Cabby accepted 164,366 POSTs/s, about **4% more** than
  ExCable's 158,494. Action Cable accepted 28,007 POSTs/s.
- **WebSocket fan-out under saturation.** Cabby delivered 471,980 messages/s, **37% more**
  than ExCable's 344,177. Action Cable delivered 59,810/s. ExCable and Cabby delivered
  **5.8× and 7.9×** as many messages/s as Action Cable, respectively.
- **WebSocket tail latency at that load.** ExCable's p99 was **9.58 ms**, about **89% lower**
  than Cabby's 88.31 ms and **79% lower** than Action Cable's 46.03 ms.

![Benchmark comparison of HTTP POSTs per second, WebSocket deliveries per second, and WebSocket p99 latency for ExCable, Cabby, and Action Cable](docs/benchmarks/capacity-comparison.svg)

### HTTP ingress

128 concurrent publishers, eight measured seconds and zero WebSocket subscribers.

| Server | Accepted POSTs/s | Accepted POSTs in 8 s | HTTP p95 / p99 (ms) |
| --- | ---: | ---: | ---: |
| ExCable | 158,494 | 1,267,954 | 2.17 / 3.59 |
| Cabby | 164,366 | 1,314,929 | 1.09 / 1.94 |
| Action Cable | 28,007 | 224,057 | 5.18 / 5.64 |

### WebSocket fan-out

240 subscribers in one room, eight concurrent publishers and an offered load of 8,000 POSTs/s.
Throughput counts completions within the ten-second window. Unsent POSTs are per-run medians.
Missing deliveries are counted after a six-second drain and totaled across the three runs.

| Server | Accepted POSTs/s | WebSocket deliveries/s | Delivery p95 / p99 (ms) | Unsent POSTs | Missing deliveries |
| --- | ---: | ---: | ---: | ---: | ---: |
| ExCable | 1,434 | 344,177 | 6.59 / 9.58 | 65,652 | 0 |
| Cabby | 1,968 | 471,980 | 21.65 / 88.31 | 60,317 | 0 |
| Action Cable | 249 | 59,810 | 43.42 / 46.03 | 77,499 | 0 |

At 1,200 offered POSTs/s, ExCable and Cabby each delivered about 288,000 messages/s
with zero unsent POSTs. Action Cable delivered about 64,000 messages/s at that load.

## Testing

### Unit and integration tests

```sh
rtk proxy mix format --check-formatted
rtk proxy mix compile --warnings-as-errors
rtk proxy mix test
```

The default suite uses real WebSocket and HTTP sockets with a local RPC fixture. To include the
Rails and multi-instance broker checks, install the pinned fixture gems and point the test suite
at Ruby and Valkey executables.

```sh
rtk proxy gem install anycable-rails-core:1.6.2 actioncable:8.1.1 railties:8.1.1 puma:7.1.0
EX_CABLE_RAILS_RUBY=/absolute/path/to/ruby \
EX_CABLE_TEST_VALKEY=/absolute/path/to/valkey-server \
  rtk proxy mix test --cover
```

### Performance and memory tests

The Go load driver exercises the standard Action Cable protocol over loopback. It verifies
every eligible delivery by sequence number and measures throughput, tail latency and reconnect
recovery. The benchmark runner can sample RSS and load the optional BEAM memory probe into a
production release. The probe records allocator blocks and carriers, occupied process heaps,
and a post-drain snapshot after a major garbage collection.

```sh
rtk proxy go -C bench test ./...
rtk proxy go -C bench build -o /tmp/excable-bench .
```

See the [comparison and soak commands](docs/benchmarks/README.md#reproduce) and the
[BEAM memory investigation](docs/benchmarks/beam-memory.md) for the matching workload,
release profiles and raw data. In the matched 20-minute churn test, the Darwin allocator
setting reduced peak ExCable RSS from 207.45 to 191.42 MiB. Both profiles completed 11,449
planned reconnects with zero missing deliveries.

[Architecture](docs/architecture.md) · [Protocols and compatibility](docs/protocol.md) ·
[Development plan](docs/plan.md) · [Tasks](docs/tasks.md) · [Benchmarks](docs/benchmarks/README.md)
