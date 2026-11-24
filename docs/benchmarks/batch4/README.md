# Four ready WebSocket frames per write

Batching lifted ExCable's median saturation throughput from **348,637 to 465,111 deliveries/s**, a **33.4% increase**. Cabby delivered **463,504/s**. The prototype led Cabby by 0.35% on the medians, but the faster server changed between rounds. At a matched 288,000 deliveries/s, Cabby had the lowest delivery p99. Four-frame writes became the default after the [hour-long churn comparisons](churn/README.md).

## Delivery latency at the same rate

All three accepted all 12,000 scheduled publications per trial and delivered all 2,880,000 eligible messages by the end of drain. The three median in-window throughputs differed by fewer than three deliveries/s.

| Server | Deliveries/s | Delivery p99 | Range of trial p99s |
| --- | ---: | ---: | ---: |
| Stock ExCable | 287,994 | 1.669 ms | 1.590–1.843 ms |
| ExCable with four-frame batching | 287,993 | 1.648 ms | 1.615–1.693 ms |
| Cabby | 287,996 | 1.512 ms | 1.474–1.519 ms |

Batching moved ExCable's median p99 by 0.021 ms (1.3%) at this rate. The stock and prototype ranges overlap. Cabby recorded the lowest p99 in every matched-rate round.

## Saturated throughput

| Server | Deliveries/s | Range of trial deliveries/s | Delivery p99 | Skipped POSTs out of 80,000 |
| --- | ---: | ---: | ---: | ---: |
| Stock ExCable | 348,637 | 346,788–350,163 | 8.062 ms | 65,466 |
| ExCable with four-frame batching | 465,111 | 463,585–478,992 | 6.012 ms | 60,613 |
| Cabby | 463,504 | 436,164–507,696 | 91.394 ms | 60,677 |

The prototype exceeded stock throughput in all three rounds. It outpaced Cabby in two rounds, and Cabby recorded the fastest individual trial at 507,696 deliveries/s. Saturation p99 reflects the volume each server actually delivered. The matched-rate table above controls for that difference.

Across all 18 timing trials, subscribers received all **64,544,160 eligible deliveries**. The driver reported zero duplicates, misroutes, publication errors, failed connection attempts or unexpected disconnects.

## How often frames shared a write

Two separate instrumented runs counted successful broadcast writes from all 240 prototype sockets. The counts include warmup, measurement and drain. Each column counts calls to the transport, regardless of how TCP segmented the bytes. [Transport probe](../../../bench/batch4/write_probe.exs)

| Offered POSTs/s | One-frame writes | Two-frame writes | Three-frame writes | Four-frame writes | Frames/write | Writes saved vs. one per frame |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,200 | 3,709,426 | 14,551 | 872 | 474 | 1.005 | 0.47% |
| 8,000 | 3,061,915 | 961,309 | 290,961 | 141,426 | 1.442 | 30.63% |

At saturation the prototype sent **6,423,120 frames in 4,455,611 writes**. At the matched load, more than 99.5% of writes carried a single frame. Batching opportunities were concentrated where the throughput gain appeared.

## What the prototype changes

When a socket handles a broadcast, it releases that message's reservation. If another reservation is outstanding, it checks the front of its mailbox for up to three more consecutive broadcasts. It checks each membership reference and sends the eligible messages in order. A lone frame can go out immediately. A queued heartbeat, disconnect or TCP command ends the batch. The existing 128-message slow-consumer limit still applies to individual messages.

Bandit 1.15.0 normally sends each frame in a WebSock list individually. The prototype serializes each of two to four uncompressed text frames separately, then passes the resulting iodata to one Thousand Island transport send. Receivers still decode individual WebSocket messages. Mixed control/data lists and compressed frames follow Bandit's existing send path. The mailbox lookahead uses `Process.info(self(), :messages)`, which takes a snapshot of the queue. Its cost is part of the measured result. [Prototype patch](../../../bench/batch4/batching.patch)

## Method

The November 24, 2026 comparison used an Apple M4 Max with 16 cores, 64 GiB RAM and macOS 27.2.1. The two ExCable production releases used the same source revision (`b31bb1b`), VM settings and locked dependencies. The prototype included the patch above. Cabby used the optimized `7b97ba1` binary from the capacity sweep. Each server, its Rails RPC fixture and the Go load generator ran on the same host over loopback. [Environment and fixture](../README.md#environment)

Each trial started a fresh server. Eight HTTP publishers sent timestamped broadcasts to one room with 240 confirmed WebSocket subscribers. After one second idle and three seconds of warmup, the driver measured ten seconds and drained for six seconds. The matched workload offered 1,200 publications/s (288,000 deliveries/s). The saturation workload offered 8,000 publications/s. Each variant ran three times at each rate, serially, rotating the first server each round.

Throughput counts unique, eligible deliveries decoded before the ten-second window ended. Delivery p99 starts when the publisher initiates its POST and ends when a subscriber decodes the frame. It includes eligible frames received during drain. A skipped POST is an offered slot that the eight publishers could not start. Loss is counted only for eligible recipients of accepted POSTs. Each table entry is the median of three trial values, including the median of the three individual p99s. [Per-trial measurements](trials.csv)

## Ordering and slow consumers

Three prototype integration tests observed actual transport sends and decoded their bytes. They checked the four-frame cap, order across a heartbeat and a stale subscription, immediate delivery of a single message, and overflow of a stalled subscriber. With one socket suspended, 128 admitted broadcasts drained in exactly 32 writes of four. The reconnectable disconnect followed those writes, and another client received all 161 of its broadcasts. The isolated prototype passed all 28 ExUnit tests with the Rails and Valkey fixtures enabled. The default build also tests a remote disconnect between broadcasts and an isolated stale message. [Current tests](../../../test/batch4_test.exs)

## Reproduce

Use the [fixture and driver setup](../README.md#reproduce) to set `BENCH_DRIVER`, `CABBY_BIN` and `BENCH_RUBY`. Set `EX_CABLE_TEST_VALKEY` to a Valkey server executable and make the fixture gems available to Ruby. Run from the ExCable checkout with its locked dependencies fetched. The preparation script extracts the historical source from Git and copies the dependencies into each new directory. Its default mode applies the benchmark patch. Use `stock` to build the corresponding baseline.

```sh
batch_dir=$(rtk proxy mktemp -d)
rtk proxy sh bench/batch4/prepare.sh "$batch_dir/stock-source" stock
(
  cd "$batch_dir/stock-source" || exit 1
  rtk proxy env MIX_ENV=prod mix release --path "$batch_dir/stock"
)
rtk proxy sh bench/batch4/prepare.sh "$batch_dir/source"
(
  cd "$batch_dir/source" || exit 1
  rtk proxy env EX_CABLE_RAILS_RUBY="$BENCH_RUBY" EX_CABLE_TEST_VALKEY="$EX_CABLE_TEST_VALKEY" mix test
  rtk proxy env MIX_ENV=prod mix release --path "$batch_dir/prototype"
)
rtk proxy python3 bench/batch4/compare.py \
  --stock "$batch_dir/stock/bin/ex_cable" --prototype "$batch_dir/prototype/bin/ex_cable" \
  --cabby "$CABBY_BIN" --ruby "$BENCH_RUBY" --driver "$BENCH_DRIVER" --out "$batch_dir/trials"
```

To inspect batch sizes, run the prototype again with its transport probe. Each socket logs its number of one-, two-, three- and four-broadcast writes when it closes. These counts include warmup and drain. The timed comparison above runs with the probe disabled.

```sh
rtk proxy env BATCH4_RELEASE="$batch_dir/prototype/bin/ex_cable" \
  python3 bench/run.py steady --servers excable --excable "$PWD/bench/batch4/profile.sh" \
  --ruby "$BENCH_RUBY" --driver "$BENCH_DRIVER" --levels 1200 8000 --rounds 1 \
  --clients 240 --publishers 8 --idle 1s --warmup 3s --duration 10s --drain 6s \
  --out "$batch_dir/profile"
rtk proxy rg '^batch4_writes ' "$batch_dir/profile"
```
