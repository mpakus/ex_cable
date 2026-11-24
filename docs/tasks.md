# Development tasks

See the [development plan](plan.md) for the order and acceptance criteria.

- [x] Verify the Action Cable WebSocket lifecycle over a real socket.
- [x] Verify HTTP RPC credentials, metadata, state patches and failure handling.
- [x] Verify HTTP broadcast authorization, stream changes and remote disconnect.
- [x] Verify Redis delivery, reconnect and fan-out across two separate BEAM instances.
- [x] Verify a real Rails connection and channel lifecycle through `anycable-rails-core`.
- [x] Check concurrent fan-out with 32 WebSockets and 1,024 ordered deliveries.
- [x] Build the OTP release and verify its health endpoint.
- [x] Measure throughput, tail latency, RSS and reconnect churn against Cabby and Rails. [Benchmark report](benchmarks/README.md)
