# ExCable, Cabby and Rails Action Cable

Measured November 24, 2026 on one Apple M4 Max with 16 cores and 64 GiB RAM, running arm64
macOS 27.2.1. ExCable used the native production release with four-frame writes from
`36ae8a4`, Elixir 1.19.5 and OTP 28.5. Cabby used the Rust release build at `7b97ba1`.
Rails used Action Cable 8.1.1, Puma 7.1.0 with five request threads and Ruby 4.0.1 with
YJIT. Both gateways used the same Rails fixture through AnyCable HTTP RPC with a pool of 16.
Native Action Cable used its in-process async adapter. These are loopback results with a
small payload and no TLS, Redis or application database.

## Workloads

Servers ran one at a time with a fresh process for each trial. The order rotated across
three rounds per workload. The Go 1.25 driver and the server shared the host. Each trial
started with three seconds of publishing warmup.

| Workload | Subscribers | Publishers | Offered load | Measurement |
| --- | ---: | ---: | --- | --- |
| HTTP ingress | 0 | 128 | Each publisher sends after its previous response | 8 s |
| Matched WebSocket fan-out | 240 in one room | 8 | 200 POSTs/s, targeting 48,000 deliveries/s | 10 s + 6 s drain |
| Saturated WebSocket fan-out | 240 in one room | 8 | 8,000 POSTs/s, targeting 1,920,000 deliveries/s | 10 s + 6 s drain |

HTTP throughput counts successful 201 responses received during the window. One accepted POST
to the room can produce 240 WebSocket deliveries. Delivery throughput counts unique eligible
frames decoded before the end of the window. Delivery latency runs from the start of the POST
to client decode and includes frames received during the drain. Missing deliveries are checked
after the drain. Unsent POSTs are scheduled calls the driver's bounded queue could not admit
before the deadline. The same offered saturation load produced different achieved rates.

## Results

Rates, counts per run, latency percentiles and peak RSS are medians of three trials.
Ranges show the minimum and maximum trial rates. RSS is the largest one-second sample
inside each measurement window. Combined RSS includes the dedicated Rails RPC process for
ExCable and Cabby. The Go driver is excluded.

### HTTP ingress

| Server | POSTs/s | Observed range | Accepted within 8 s | HTTP p95 / p99 (ms) |
| --- | ---: | ---: | ---: | ---: |
| ExCable | 166,529 | 164,527–167,298 | 1,332,235 | 2.165 / 3.663 |
| Cabby | 167,456 | 167,198–167,730 | 1,339,649 | 1.022 / 1.847 |
| Rails Action Cable | 28,250 | 28,221–28,580 | 225,997 | 5.087 / 5.478 |

### Matched fan-out

| Server | Accepted POSTs/s | Delivered/s | Observed range | Delivery p95 / p99 (ms) | Unsent POSTs | Primary / combined peak RSS (MiB) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| ExCable | 200.0 | 48,000 | 48,000–48,000 | 2.308 / 3.189 | 0 | 186.0 / 262.5 |
| Cabby | 200.0 | 48,000 | 48,000–48,000 | 2.176 / 3.147 | 0 | 18.8 / 98.9 |
| Rails Action Cable | 200.0 | 48,000 | 48,000–48,000 | 3.836 / 4.422 | 0 | 89.8 / 89.8 |

### Saturated fan-out

| Server | Accepted POSTs/s | Delivered/s | Observed range | Delivery p95 / p99 (ms) | Unsent POSTs | Primary / combined peak RSS (MiB) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| ExCable | 2,112.8 | 507,084 | 504,346–508,101 | 5.158 / 5.934 | 58,864 | 208.8 / 289.0 |
| Cabby | 2,145.7 | 514,368 | 445,921–532,069 | 8.508 / 17.100 | 58,535 | 20.9 / 101.0 |
| Rails Action Cable | 252.6 | 60,599 | 60,309–64,259 | 42.021 / 43.846 | 77,466 | 89.8 / 89.8 |

Cabby led ExCable in two saturation trials. Its wider throughput range spanned all three
ExCable results. ExCable recorded the lowest saturated delivery p99 in every round, from
5.877 to 5.983 ms. At the matched rate the gap between their median p99s was 0.042 ms.
All 27 trials had zero HTTP publication errors. Across the 18 WebSocket trials, all
36,315,360 eligible deliveries arrived, with zero duplicates, misroutes or unexpected
disconnects. These workloads kept clients connected. Reconnect recovery is measured in
the [separate one-hour churn runs](../batch4/churn/README.md).

## Reproduce

Follow the [build and fixture setup](../README.md#reproduce). Use a fresh output directory.

```sh
rtk proxy python3 bench/run.py ingress --rounds 3 --levels 128 --duration 8s --warmup 3s \
  --driver "$BENCH_DRIVER" --cabby "$CABBY_BIN" --ruby "$BENCH_RUBY" --out /tmp/excable-current
rtk proxy python3 bench/run.py steady --rounds 3 --levels 200 8000 --clients 240 --publishers 8 \
  --duration 10s --warmup 3s --idle 1s --drain 6s --driver "$BENCH_DRIVER" \
  --cabby "$CABBY_BIN" --ruby "$BENCH_RUBY" --out /tmp/excable-current
rtk proxy python3 bench/plot_capacity.py /tmp/excable-current /tmp/comparison.png
```

The plotting command requires Matplotlib. The [per-trial measurements](trials.csv)
contain rates, counts, latency percentiles and peak RSS. The [raw archive](raw.tar.gz)
contains the driver's original `load.json` and the runner's `rss.csv` for each trial.
Extract it into an empty directory and pass that directory to the plotting command to
regenerate the published chart.
