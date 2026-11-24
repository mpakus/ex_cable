# Development plan

ExCable moves Action Cable WebSockets out of Rails. The first release targets the standard
`actioncable-v1-json` protocol and the HTTP RPC interface provided by `anycable-rails-core`.
Rails remains responsible for application identity, authorization and channel callbacks.

1. **Wire compatibility.** Verify negotiation, origin policy, lifecycle and opaque identifiers
   with real WebSocket frames and requests against a contract backend.
2. **Broadcast and scale-out.** Verify stream mutations, local HTTP ingress and Redis Pub/Sub
   across instances. Keep connection, channel and stream state local to each node.
3. **Rails acceptance.** Run a small Rails fixture with cookie authentication, an authorized and
   a denied subscription, a channel action, a broadcast, and both unsubscribe and disconnect.
4. **Performance acceptance.** Compare idle RSS, delivery throughput and p95/p99 latency against
   Cabby and Rails using the same client workload, hardware and payloads. Include a slow reader,
   broker interruption and reconnect churn. Account for messages sent, received and lost.
