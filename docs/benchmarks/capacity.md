# HTTP and WebSocket capacity sweep

Measured on November 24, 2026 on the same 16-core Apple M4 Max host as the
[earlier comparison](README.md). ExCable ran the Darwin production release with
the 256 KiB binary allocator threshold. Cabby ran the optimized local build at
`7b97ba1794639906bc9d37c3f645456ad224ec43`. Native Action Cable used Rails and
Railties 8.1.1 and Puma 7.1.0 with five request threads. The Rails fixture used
Ruby 4.0.1 with YJIT. Both gateways called that same fixture over HTTP RPC.

## Results

Each capacity-sweep point ran once. The 128-publisher HTTP point and 8,000 POSTs/s
fan-out point include two more trials. Rows with three runs use medians for rates,
latencies, requests and unsent slots. Error, missing and disconnect counts are sums.
The receipt of HTTP `201` measures broadcast acceptance. A WebSocket delivery is
counted when a subscriber decodes the matching frame.

### HTTP ingress without subscribers

| Concurrent publishers | Server | Runs | Accepted POSTs/s | In-window 201s / attempts per run | HTTP p95 / p99 (ms) | HTTP errors |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 8 | ExCable | 1 | 95,521 | 764,170 / 764,178 | 0.12 / 0.16 | 0 |
| 8 | Cabby | 1 | 118,562 | 948,500 / 948,508 | 0.10 / 0.12 | 0 |
| 8 | Action Cable | 1 | 26,832 | 214,660 / 214,668 | 0.40 / 0.68 | 0 |
| 32 | ExCable | 1 | 135,864 | 1,086,911 / 1,086,943 | 0.40 / 0.60 | 0 |
| 32 | Cabby | 1 | 161,198 | 1,289,587 / 1,289,619 | 0.31 / 0.45 | 0 |
| 32 | Action Cable | 1 | 28,417 | 227,337 / 227,369 | 1.39 / 1.65 | 0 |
| 64 | ExCable | 1 | 152,124 | 1,216,991 / 1,217,055 | 0.88 / 1.43 | 0 |
| 64 | Cabby | 1 | 165,247 | 1,321,977 / 1,322,041 | 0.56 / 0.89 | 0 |
| 64 | Action Cable | 1 | 27,492 | 219,932 / 219,996 | 2.76 / 3.10 | 0 |
| 128 | ExCable | 3 | 158,494 | 1,267,954 / 1,268,082 | 2.17 / 3.59 | 0 |
| 128 | Cabby | 3 | 164,366 | 1,314,929 / 1,315,057 | 1.09 / 1.94 | 0 |
| 128 | Action Cable | 3 | 28,007 | 224,057 / 224,185 | 5.18 / 5.64 | 0 |
| 256 | ExCable | 1 | 159,663 | 1,277,307 / 1,277,563 | 4.86 / 8.91 | 0 |
| 256 | Cabby | 1 | 165,895 | 1,327,157 / 1,327,413 | 1.90 / 3.77 | 0 |
| 256 | Action Cable | 1 | 27,586 | 220,687 / 220,943 | 11.52 / 15.09 | 0 |

The highest observed HTTP rates were 159,663 POSTs/s for ExCable and 165,895 for
Cabby at 256 publishers, and 28,417 for Action Cable at 32 publishers.

### WebSocket fan-out to 240 subscribers

| Offered POSTs/s | Server | Runs | Accepted POSTs/s | Deliveries/s | Delivery p95 / p99 (ms) | Unsent POSTs per run | HTTP errors | Missing deliveries | Unexpected disconnects |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 200 | ExCable | 1 | 200.0 | 48,000 | 2.63 / 3.44 | 0 | 0 | 0 | 0 |
| 200 | Cabby | 1 | 200.0 | 48,000 | 2.42 / 3.29 | 0 | 0 | 0 | 0 |
| 200 | Action Cable | 1 | 200.0 | 48,000 | 3.80 / 4.40 | 0 | 0 | 0 | 0 |
| 400 | ExCable | 1 | 400.0 | 96,000 | 1.50 / 2.61 | 0 | 0 | 0 | 0 |
| 400 | Cabby | 1 | 400.0 | 96,000 | 1.54 / 2.69 | 0 | 0 | 0 | 0 |
| 400 | Action Cable | 1 | 261.7 | 62,798 | 41.18 / 43.65 | 1,375 | 0 | 0 | 0 |
| 800 | ExCable | 1 | 799.9 | 191,995 | 0.93 / 1.12 | 0 | 0 | 0 | 0 |
| 800 | Cabby | 1 | 800.0 | 192,000 | 0.89 / 1.24 | 0 | 0 | 0 | 0 |
| 800 | Action Cable | 1 | 266.7 | 63,982 | 40.00 / 42.20 | 5,325 | 0 | 0 | 0 |
| 1,200 | ExCable | 1 | 1,199.9 | 287,990 | 1.14 / 1.68 | 0 | 0 | 0 | 0 |
| 1,200 | Cabby | 1 | 1,200.0 | 287,991 | 1.08 / 1.47 | 0 | 0 | 0 | 0 |
| 1,200 | Action Cable | 1 | 267.5 | 64,162 | 39.55 / 41.25 | 9,317 | 0 | 0 | 0 |
| 2,400 | ExCable | 1 | 1,456.5 | 349,585 | 6.62 / 7.85 | 9,427 | 0 | 0 | 0 |
| 2,400 | Cabby | 1 | 1,762.0 | 422,708 | 7.67 / 10.30 | 6,372 | 0 | 0 | 0 |
| 2,400 | Action Cable | 1 | 267.8 | 64,224 | 39.84 / 42.16 | 21,314 | 0 | 0 | 0 |
| 4,800 | ExCable | 1 | 1,459.3 | 350,269 | 6.49 / 7.47 | 33,399 | 0 | 0 | 0 |
| 4,800 | Cabby | 1 | 1,822.2 | 432,590 | 19.46 / 101.37 | 29,770 | 0 | 0 | 0 |
| 4,800 | Action Cable | 1 | 250.5 | 60,084 | 42.60 / 45.06 | 45,487 | 0 | 0 | 0 |
| 8,000 | ExCable | 3 | 1,434.0 | 344,177 | 6.59 / 9.58 | 65,652 | 0 | 0 | 0 |
| 8,000 | Cabby | 3 | 1,967.5 | 471,980 | 21.65 / 88.31 | 60,317 | 0 | 0 | 0 |
| 8,000 | Action Cable | 3 | 249.3 | 59,810 | 43.42 / 46.03 | 77,499 | 0 | 0 | 0 |

All three reached 48,000 deliveries/s at 200 offered POSTs/s. At 1,200 offered POSTs/s,
ExCable and Cabby each delivered about 288,000/s with zero missing deliveries and zero
unsent slots. The highest observed delivery rates were 353,164/s for ExCable and
488,739/s for Cabby at 8,000 offered POSTs/s, and 64,224/s for Action Cable at
2,400 offered POSTs/s. At 8,000 offered POSTs/s, Cabby's delivery p99 ranged from
9.75 to 111.66 ms across the three trials.

## Workloads

**HTTP ingress.** A fixed number of persistent HTTP/1.1 publishers posted one small
JSON broadcast per request, with no WebSocket subscribers. Each publisher sent its
next request immediately after a response. The runner tested 8, 32, 64, 128 and 256
publishers, with a three-second warmup and an eight-second measurement window.

**WebSocket fan-out.** 240 clients subscribed to one room through the standard
Action Cable protocol. Eight persistent HTTP publishers offered the same sequence
of broadcasts to each server. The driver kept at most eight requests queued in
addition to the eight in flight. If the queue filled or the measurement window
closed, it counted the unsent slot. Each trial used a three-second publishing
warmup, ten measured seconds and a six-second drain.

The comparison ran one server at a time and rotated server order. The driver and
server shared the same host over loopback TCP. Its results describe the observed
capacity of this server, fixture and driver configuration.

HTTP rate counts successful `201` responses completed in the window. WebSocket
rate counts unique, eligible deliveries received in the same window. The driver
reconciles delivery IDs through the end of the drain and reports missing deliveries,
duplicates and unexpected disconnects separately from unsent HTTP requests. Late
successful HTTP responses and their deliveries remain eligible for loss accounting.
Both latency distributions measure from the time the driver starts the HTTP request.

## Reproduce

Build the release and load driver and install the Rails fixture gems using the
[comparison setup](README.md#reproduce). Set `BENCH_DRIVER`, `CABBY_BIN` and
`BENCH_RUBY` to the corresponding executables.

```sh
rtk proxy python3 bench/run.py steady --levels 200 400 800 1200 2400 4800 8000 \
  --publishers 8 --rounds 1 --duration 10s --warmup 3s --idle 1s --drain 6s \
  --driver "$BENCH_DRIVER" --cabby "$CABBY_BIN" --ruby "$BENCH_RUBY" \
  --out /tmp/excable-capacity

rtk proxy python3 bench/run.py ingress --levels 8 32 64 128 256 \
  --rounds 1 --duration 8s --warmup 3s \
  --driver "$BENCH_DRIVER" --cabby "$CABBY_BIN" --ruby "$BENCH_RUBY" \
  --out /tmp/excable-capacity

rtk proxy python3 bench/run.py steady --levels 8000 \
  --publishers 8 --rounds 2 --duration 10s --warmup 3s --idle 1s --drain 6s \
  --driver "$BENCH_DRIVER" --cabby "$CABBY_BIN" --ruby "$BENCH_RUBY" \
  --out /tmp/excable-capacity-repeat

rtk proxy python3 bench/run.py ingress --levels 128 \
  --rounds 2 --duration 8s --warmup 3s \
  --driver "$BENCH_DRIVER" --cabby "$CABBY_BIN" --ruby "$BENCH_RUBY" \
  --out /tmp/excable-capacity-repeat
```

[Raw sweep results](capacity-sweep/) · [Raw repeat trials](capacity-repeat/)
