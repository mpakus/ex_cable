# Where ExCable can gain throughput

Cabby delivered **465,985 messages/s** against **346,721/s** for stock ExCable at the highest offered load. ExCable needs roughly **34% more delivered throughput** to match Cabby on this host. ExCable needed **4.1%** more throughput to match Cabby on HTTP ingress without subscribers. In fan-out, ExCable's delivery p99 was **7.61 ms** and Cabby's was **102.95 ms**. They accepted different amounts of work at saturation. At the earlier matched load of about 288,000 deliveries/s, p99 was 1.68 ms for ExCable and 1.47 ms for Cabby. [Matched-load results](../capacity.md)

## Measurements

| Fan-out with 240 subscribers | Deliveries/s | Delivery p95 | Delivery p99 | Unexpected disconnects across three trials |
| --- | ---: | ---: | ---: | ---: |
| Stock ExCable | 346,721 | 6.52 ms | 7.61 ms | 0 |
| ExCable with delayed TCP sends | 350,298 | 6.62 ms | 12.65 ms | 6 |
| Cabby | 465,985 | 40.01 ms | 102.95 ms | 0 |

Delaying sends across the listener bought 1.0% in throughput. All six unexpected disconnects occurred in one trial. The loss counter evaluates messages for which the socket was eligible, so a zero loss count can coexist with a reconnect. This setting is a poor trade under this load.

| Separate paired fan-out experiment | Deliveries/s | Delivery p95 | Delivery p99 | Unexpected disconnects across three trials |
| --- | ---: | ---: | ---: | ---: |
| Stock ExCable | 347,016 | 6.45 ms | 7.41 ms | 0 |
| ExCable sharing the complete JSON message | 346,090 | 6.55 ms | 7.73 ms | 0 |

The shared-message prototype finished 0.27% below its paired baseline, within the observed run-to-run spread. Even this favorable single-identifier workload gave little reason to add a frame cache on its own.

| HTTP with zero subscribers | Accepted POSTs/s | HTTP p95 | HTTP p99 |
| --- | ---: | ---: | ---: |
| Stock ExCable | 161,052 | 2.15 ms | 3.67 ms |
| ExCable with one Registry partition | 161,048 | 1.97 ms | 3.10 ms |
| Cabby | 167,712 | 1.00 ms | 1.81 ms |

One partition improved HTTP p99 by about 15% in this experiment. The two throughput medians differed by four POSTs/s. Sustained login and subscription churn would be a separate test of the cost of concentrating Registry writes.

## What the servers do differently

An ExCable broadcast POST validates the envelope and its embedded JSON, looks up stream members, and enqueues a message to each eligible socket before returning `201`. Each socket checks its membership reference and wraps the data with its cached channel identifier. Bandit 1.15.0 serializes and sends each WebSocket frame. Returning a list of frames through WebSock still calls the send path for each frame. [ExCable broadcast](../../../lib/ex_cable/broadcast.ex) · [socket callback](../../../lib/ex_cable/socket.ex) · [Bandit send loop](https://preview.hex.pm/preview/bandit/1.15.0/show/lib/bandit/websocket/connection.ex)

Cabby caches a membership snapshot grouped by channel identifier and shares the encoded message among that group's recipients. A bounded gate queue decouples HTTP acceptance from most of the work of walking the stream. The connection writer takes the frames already waiting, feeds them individually, and flushes once. These differences can raise throughput and can also let more work accumulate between HTTP acceptance and delivery. [Cabby hub](https://github.com/DaniG2k/cabby/blob/7b97ba1794639906bc9d37c3f645456ad224ec43/crates/cabby-core/src/hub.rs) · [connection writer](https://github.com/DaniG2k/cabby/blob/7b97ba1794639906bc9d37c3f645456ad224ec43/crates/cabby-server/src/ws/connection.rs)

At 240 deliveries per publication, matching 465,985 deliveries/s takes about 1,942 publications/s. With only eight requests in flight, that requires an average request turnaround of about 4.12 ms or less. ExCable's stock delivery rate corresponds to about 1,445 publications/s. In one follow-up run with 32 publishers, ExCable delivered 342,950/s with 24.61 ms p99 and Cabby delivered 503,777/s with 99.33 ms p99. Giving the driver four times as many in-flight slots filled more of ExCable’s latency budget without raising its observed delivery rate.

## What was waiting on the socket

A separate instrumented stock run delivered 345,890 messages/s. Across 14,595 samples from 25 sockets, **27.15%** had another broadcast at the head of the remaining mailbox, **1.71%** had at least three, and **0.05%** had at least seven. Small batches can form naturally under saturation. Waiting for eight frames would add latency to most sampled callbacks. These observations describe available work. Measuring transport writes is still necessary to estimate the savings. [Mailbox histogram and CPU samples](queue-sample.json)

During 9.28 measured seconds, the BEAM consumed an average of **7.65 CPU cores** and the Go driver **5.88**. Rails RPC used less CPU than the sampling resolution. The driver decodes both the outer Action Cable frame and the embedded event before recording its delivery timestamp. Moving the driver off the server is a priority for measuring the remaining gap. [Driver receive path](../../../bench/load.go) · [CPU samples](queue-sample.json)

## How to test the next change

1. **Locate the throughput ceiling.** Put the Go driver on a second host and rerun both servers with the same CPU budget. Measure time in ExCable's Registry dispatch, mailbox wait and transport send on a sample of connections. Compare p99 at equal *delivered* rates as well as at saturation. The earlier 1,200 POSTs/s point gives a common starting load.
2. **Test write batching at the transport boundary.** Have the connection owner drain a capped number of consecutive ready frames into a single socket send without waiting for a timer. Preserve WebSocket frame boundaries, control-frame ordering, subscription membership checks and the existing slow-consumer budget. Count frames per actual transport send and test an idle room as well as a saturated one. A WebSock list alone still takes Bandit's per-frame send path.
3. **Try bounded admission if HTTP dispatch holds publishers up.** Assign streams to a fixed pool of supervised workers by key. Validate the entire input batch first. Reserve queue capacity before acknowledging a POST and apply backpressure when full. Track queue age and bytes alongside end-to-end delivery. A quicker `201` helps only if subscribers also receive more messages within the window.

The isolated shared-message prototype passed all 25 ExUnit tests, including Rails and Valkey integration. Across the 27 benchmark trials, the driver reported zero HTTP errors, missing eligible deliveries, duplicates or misrouted frames. The six unexpected disconnects are recorded above.

A convincing win would repeat higher *delivered* throughput than Cabby under the same load and hardware budget, while preserving ExCable's delivery p99 at matched rates. Check unsent POSTs, HTTP errors, missing and duplicate deliveries, unexpected reconnects and peak RSS. Repeat with many small rooms, mixed channel identifiers, and the [churn soak](../README.md) before selecting a default.

## Experimental setup

Tests ran on November 24, 2026 on one 16-core Apple M4 Max. ExCable was built from `b31bb1b` with statistics counters present. Cabby was the same optimized `7b97ba1` binary used in the [capacity sweep](../capacity.md). The server, Rails fixture and Go client shared the host. Each server started fresh, warmed up for three seconds, and ran alone. The fan-out workload used 240 subscribers with the same channel identifier in one room, eight publishers, 8,000 offered POSTs/s, ten measured seconds and a six-second drain. The ingress workload used 128 persistent publishers, zero subscribers and eight measured seconds.

Each optimization comparison used three trials per build. The 32-publisher check ran once per server. The queue diagnostic ran once, for 27 trials in total. The first two comparisons rotated the three builds through the three run positions. The shared-frame comparison alternated which of its two builds ran first. Rates count completions inside the measurement window. Delivery latency starts when a publisher starts its HTTP request and ends after the Go client decodes the frame. Percentiles in the tables are medians of the per-trial percentiles. The client records skipped publication slots separately from losses among eligible subscribers. [Per-trial measurements](trials.csv)

### Reproduce the candidates

Use separate copies of the source at `b31bb1b` and build each with `MIX_ENV=prod rtk proxy mix release`. The [capacity sweep commands](../capacity.md#reproduce) set up the Ruby fixture and driver. Pass `--excable /path/to/release/bin/ex_cable` to select each build. For fan-out use `--levels 8000 --publishers 8 --duration 10s --warmup 3s --idle 1s --drain 6s`. For ingress use `--levels 128 --duration 8s --warmup 3s`. Rotate builds between runs.

- **Delayed TCP sends.** Add `delay_send: true` beside `send_timeout` in the listener's `transport_options`. This applies to the shared HTTP and WebSocket listener. OTP can combine queued sends at the transport layer. [OTP socket options](https://www.erlang.org/doc/apps/kernel/inet.html#setopts/2)
- **One Registry partition.** Change `partitions: System.schedulers_online()` to `partitions: 1` in `ExCable.Application`. On the tested Elixir 1.19.5 implementation, the existing duplicate Registry dispatch checks each partition even when the stream is empty. One partition exercises a single lookup. [Registry dispatch](https://elixir.hexdocs.pm/1.19/Registry.html#dispatch/4)
- **Shared message.** Apply the [shared-frame patch](shared-frame.patch). It builds a complete Action Cable JSON message once per consecutive group of equal identifiers within each Registry callback. All recipients in the benchmark used the same identifier. Each socket still checks membership and sends an individual WebSocket frame. Ref-counted binaries can share storage across local BEAM processes. [OTP message copying](https://www.erlang.org/doc/system/eff_guide_processes.html#sending-messages)
- **Diagnostic build.** Apply the [queue probe](queue-probe.patch) alone to the stock build and point `BENCH_PROFILE_DIR` at an existing empty directory. It selects each socket with probability 1/8, then samples every 32nd broadcast with a randomized initial phase. Each observation counts consecutive broadcast messages at the head of the remaining mailbox, capped at 15. Other queued work is an ordering boundary. The per-socket histogram includes warmup and is written when the socket terminates.
