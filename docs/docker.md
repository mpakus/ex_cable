# Run ExCable in Docker

The image builds the locked production Mix release, including the Bandit transport patch,
and runs it as an unprivileged user. The runtime includes the BEAM, CA certificates and
`/app/bin/cli`. Rails owns authentication, subscription decisions and channel callbacks.
Use the [Rails setup and Docker command](../README.md#run-with-rails) to get started.

## Addresses and credentials

Configure each address for the process that opens the connection. These examples assume
the browser visits Rails at `http://localhost:3000` and connects to ExCable at
`ws://localhost:8080/cable`.

| Connection | Docker Desktop with Rails on the host | Both containers on one user-defined network |
| --- | --- | --- |
| ExCable → Rails, `EX_CABLE_RPC_URL` | `http://host.docker.internal:3000/_anycable` | `http://rails:3000/_anycable` |
| Rails → ExCable, `ANYCABLE_HTTP_BROADCAST_URL` | `http://127.0.0.1:8080/_broadcast` | `http://ex-cable:8080/_broadcast` |
| Browser → ExCable, `ANYCABLE_WEBSOCKET_URL` on Rails and `EX_CABLE_PUBLIC_URL` on ExCable | `ws://localhost:8080/cable` | `ws://localhost:8080/cable` |
| Browser origin, `EX_CABLE_ALLOWED_ORIGINS` on ExCable | `http://localhost:3000` | `http://localhost:3000` |

On **Linux Docker Engine** with host Rails, add `--add-host host.docker.internal:host-gateway`
to the run command. Bind Rails to an address reachable from the Docker bridge and allow
its RPC hostname through Rails host authorization, for example
`config.hosts << "host.docker.internal"` in development. On a shared network, join ExCable
with `--network <network>` and substitute the Rails and ExCable service names from that
network. Rails must listen on its container interface. [Docker host gateway](https://docs.docker.com/reference/cli/docker/container/run/#add-host)

Pass the same `ANYCABLE_SECRET` to both processes at runtime. In production set the public
cable URL to `wss://…/cable`, allow the exact HTTPS application origin, and forward WebSocket
upgrades through your reverse proxy. Restrict RPC, broadcast and statistics access to their
intended callers. Multiple ExCable instances use Redis Pub/Sub as described in the
[scale-out configuration](../README.md#run-multiple-instances).

## Operate the image

The default port is 8080. To change it, set `PORT` and update the container side of the
published port. Docker probes `/healthz` on this port. A configured Redis subscription must be
ready for the probe to pass. Rails RPC is exercised when a client connects.

```sh
rtk proxy docker inspect --format '{{.State.Health.Status}}' ex-cable
rtk proxy docker logs ex-cable
rtk proxy docker exec -it ex-cable /app/bin/cli -f
rtk proxy docker stop ex-cable
```

For the CLI, also pass `-e EX_CABLE_STATS_KEY` when starting the container. When overriding
`PORT`, pass `--url http://127.0.0.1:<port>` to the CLI. ExCable runs in the foreground
and receives Docker's termination signal directly.

## Test the image

Install the host-side Elixir test dependencies and the [pinned Rails fixture gems](../README.md#unit-and-integration-tests).
The test starts a disposable container from the specified image and a Rails fixture on the
host. It checks readiness, browser origin rejection, WebSocket protocol negotiation, cookie
authentication, allowed and rejected subscriptions, a channel action, a broadcast from Rails,
and unsubscribe and disconnect callbacks.

```sh
rtk proxy docker build -t ex-cable:local .
export EX_CABLE_RAILS_RUBY="$(command -v ruby)"
export EX_CABLE_DOCKER_IMAGE=ex-cable:local
rtk proxy mix test test/rails_test.exs
```

Use the Ruby executable that has the fixture gems installed. The test keeps Rails on host
loopback. It uses Docker Desktop's built-in host gateway on macOS and host networking on
native Linux Engine. The gateway and fixture use temporary ports.
