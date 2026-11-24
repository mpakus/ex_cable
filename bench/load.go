package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net/http"
	"os"
	"slices"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type options struct {
	url, key                    string
	clients, rooms, rate, seed  int
	publishers, burst           int
	ingress                     bool
	duration, warmup, low, high time.Duration
	guard, idle, drain, offline time.Duration
}

type event struct {
	Sequence int   `json:"seq"`
	SentNS   int64 `json:"sent_unix_ns"`
}

type window struct{ begin, end time.Time }
type reconnect struct {
	down, up time.Time
	planned  bool
}

type client struct {
	room                int
	deliveryUS          []int64
	windows             []window
	reconnects          []reconnect
	connectErrors       []time.Time
	duplicates, invalid int
}

func main() {
	var o options
	flag.StringVar(&o.url, "url", "", "Loopback server base URL")
	flag.StringVar(&o.key, "key", "", "Broadcast authorization key")
	flag.IntVar(&o.clients, "clients", 300, "Concurrent clients")
	flag.IntVar(&o.rooms, "rooms", 1, "Rooms")
	flag.IntVar(&o.rate, "rate", 50, "Scheduled publications per second")
	flag.IntVar(&o.publishers, "publishers", 1, "Maximum concurrent HTTP publishers")
	flag.IntVar(&o.burst, "burst", 1, "Publications scheduled together for the same room")
	flag.BoolVar(&o.ingress, "ingress", false, "Measure HTTP publication capacity without WebSocket subscribers")
	flag.IntVar(&o.seed, "seed", 20261123, "Reconnect interval seed")
	flag.DurationVar(&o.warmup, "warmup", 5*time.Second, "Unmeasured publication warmup")
	flag.DurationVar(&o.duration, "duration", 15*time.Second, "Measurement duration")
	flag.DurationVar(&o.low, "lifetime-min", 0, "Minimum connection lifetime (zero disables churn)")
	flag.DurationVar(&o.high, "lifetime-max", 0, "Maximum connection lifetime")
	flag.DurationVar(&o.idle, "idle", 4*time.Second, "Connected idle window")
	flag.DurationVar(&o.drain, "drain", 5*time.Second, "Time to receive remaining measured messages")
	flag.DurationVar(&o.guard, "guard", 200*time.Millisecond, "Ambiguity margin on either end of an active interval")
	flag.DurationVar(&o.offline, "offline", 100*time.Millisecond, "Delay before attempting a reconnect")
	flag.Parse()
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	if o.url == "" || o.clients < 1 || o.rooms < 1 || o.rooms > o.clients || o.rate < 1 || o.publishers < 1 ||
		o.burst < 1 || o.burst > o.publishers || o.low < 0 || o.high < o.low || o.duration <= 0 || o.warmup < 0 {
		log.Fatal("Invalid workload parameters")
	}
	workload := run
	if o.ingress {
		workload = runIngress
	}
	if err := workload(o); err != nil {
		log.Fatal(err)
	}
}

func run(o options) error {
	warmupCount := int(o.warmup.Seconds() * float64(o.rate))
	measuredCount := int(o.duration.Seconds() * float64(o.rate))
	total := warmupCount + measuredCount
	if measuredCount < 1 {
		return fmt.Errorf("measurement schedules no events")
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ready := make(chan struct{}, o.clients)
	clients := make([]client, o.clients)
	var wsGroup sync.WaitGroup
	for index := range clients {
		c := &clients[index]
		c.room = index % o.rooms
		c.deliveryUS = make([]int64, 1+total/o.rooms)
		wsGroup.Go(func() { c.follow(ctx, o, index, total, warmupCount, ready) })
	}

	startup := time.NewTimer(30 * time.Second)
	defer startup.Stop()
	for confirmed := range clients {
		select {
		case <-ready:
		case <-startup.C:
			cancel()
			wsGroup.Wait()
			return fmt.Errorf("startup timed out before all %d clients subscribed (%d ready)", o.clients, confirmed)
		}
	}

	idleStart := time.Now()
	log.Printf("Connected idle starts with %d confirmed subscriptions", o.clients)
	time.Sleep(o.idle)
	start := time.Now()
	measuredStart := start.Add(o.warmup)
	measuredEnd := measuredStart.Add(o.duration)
	publications := publish(o, start, warmupCount, total, measuredStart, measuredEnd)
	finish := time.Now()
	log.Print("Publisher complete, draining")
	time.Sleep(o.drain)
	cancel()
	wsGroup.Wait()
	end := time.Now()

	published := make([]time.Time, total)
	for seq, request := range publications {
		if request.accepted {
			published[seq] = request.sent
		}
	}
	result := summarize(o, clients, published, warmupCount, measuredStart, measuredEnd)
	result["burst_size"] = o.burst
	result["publishers"] = o.publishers
	summarizeHTTP(result, publications[warmupCount:], measuredEnd, o.duration)
	result["connected_idle_from"] = idleStart.Format(time.RFC3339Nano)
	result["publishing_from"] = start.Format(time.RFC3339Nano)
	result["measuring_from"] = measuredStart.Format(time.RFC3339Nano)
	result["measuring_to"] = measuredEnd.Format(time.RFC3339Nano)
	result["publishing_to"] = finish.Format(time.RFC3339Nano)
	result["receiving_to"] = end.Format(time.RFC3339Nano)
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(result)
}

func (c *client) follow(ctx context.Context, o options, index, total, warmupCount int, ready chan<- struct{}) {
	if !wait(ctx, time.Duration(index)*3*time.Millisecond) {
		return
	}
	rng := rand.New(rand.NewSource(int64(o.seed) + int64(index)))
	room := roomName(c.room)
	identifier := string(mustJSON(map[string]string{"channel": "BenchChannel", "room": room}))
	var activeReconnect *reconnect
	for ctx.Err() == nil {
		ws, err := subscribe(o.url, identifier)
		if err != nil {
			c.connectErrors = append(c.connectErrors, time.Now())
			if !wait(ctx, o.offline) {
				break
			}
			continue
		}
		begin := time.Now()
		closeOnCancel := context.AfterFunc(ctx, func() { ws.Close() })
		if activeReconnect != nil {
			activeReconnect.up = begin
			c.reconnects = append(c.reconnects, *activeReconnect)
		}
		if len(c.windows) == 0 {
			ready <- struct{}{}
		}

		var timer *time.Timer
		cut := time.Time{}
		if o.low > 0 {
			interval := o.low + time.Duration(rng.Int63n(int64(o.high-o.low)+1))
			timer = time.AfterFunc(interval, func() { ws.Close() })
			cut = begin.Add(interval)
		}
		c.read(ws, identifier, o.rooms, total, warmupCount)
		down := time.Now()
		if timer != nil {
			timer.Stop()
		}
		closeOnCancel()
		ws.Close()
		c.windows = append(c.windows, window{begin, down})
		if ctx.Err() != nil {
			return
		}
		activeReconnect = &reconnect{down: down, planned: !cut.IsZero() && !down.Before(cut.Add(-time.Millisecond))}
		if !wait(ctx, o.offline) {
			break
		}
	}
	if activeReconnect != nil && activeReconnect.up.IsZero() {
		c.reconnects = append(c.reconnects, *activeReconnect)
	}
}

func subscribe(base, identifier string) (*websocket.Conn, error) {
	dialer := websocket.Dialer{HandshakeTimeout: 3 * time.Second, Subprotocols: []string{"actioncable-v1-json"}}
	headers := http.Header{"Cookie": {"bench=member"}}
	ws, res, err := dialer.Dial("ws"+base[4:]+"/cable", headers)
	if err != nil {
		if res != nil {
			res.Body.Close()
		}
		return nil, err
	}
	ws.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		_, body, err := ws.ReadMessage()
		if err != nil {
			ws.Close()
			return nil, err
		}
		var control struct{ Type, Identifier string }
		if err := json.Unmarshal(body, &control); err != nil {
			ws.Close()
			return nil, err
		}
		switch control.Type {
		case "welcome":
			err = ws.WriteJSON(map[string]string{"command": "subscribe", "identifier": identifier})
			if err != nil {
				ws.Close()
				return nil, err
			}
		case "confirm_subscription":
			if control.Identifier == identifier {
				ws.SetReadDeadline(time.Time{})
				return ws, nil
			}
		case "disconnect", "reject_subscription":
			ws.Close()
			return nil, fmt.Errorf("subscription refused: %s", body)
		}
	}
}

func (c *client) read(ws *websocket.Conn, id string, rooms, total, warmup int) {
	for {
		_, body, err := ws.ReadMessage()
		if err != nil {
			return
		}
		var data struct {
			Type, Identifier string
			Message          json.RawMessage
		}
		if json.Unmarshal(body, &data) != nil {
			c.invalid++
			continue
		}
		if data.Type == "disconnect" {
			return
		}
		if data.Type != "" {
			continue
		}
		var e event
		if json.Unmarshal(data.Message, &e) != nil || e.SentNS <= 0 || e.Sequence < 0 || e.Sequence >= total ||
			e.Sequence%rooms != c.room || data.Identifier != id {
			c.invalid++
			continue
		}
		slot := e.Sequence / rooms
		if c.deliveryUS[slot] != 0 {
			if e.Sequence >= warmup {
				c.duplicates++
			}
		} else {
			c.deliveryUS[slot] = max(1, (time.Now().UnixNano()-e.SentNS)/1000)
		}
	}
}

func broadcastBody(room, seq int, sent time.Time) []byte {
	return mustJSON(map[string]string{
		"stream": roomName(room),
		"data":   string(mustJSON(event{seq, sent.UnixNano()})),
	})
}

func put(h *http.Client, o options, seq int, payload []byte) bool {
	req, err := http.NewRequest(http.MethodPost, o.url+"/_broadcast", bytes.NewReader(payload))
	if err != nil {
		panic(err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+o.key)
	res, err := h.Do(req)
	if err != nil {
		log.Printf("Publish %d: %v", seq, err)
		return false
	}
	io.Copy(io.Discard, res.Body)
	res.Body.Close()
	if res.StatusCode != http.StatusCreated {
		log.Printf("Publish %d: status %d", seq, res.StatusCode)
		return false
	}
	return true
}

func roomName(i int) string { return fmt.Sprintf("bench-%d", i) }

func mustJSON(value any) []byte {
	body, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return body
}

func wait(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return true
	case <-ctx.Done():
		return false
	}
}

func summarize(o options, clients []client, published []time.Time, warmup int, start, end time.Time) map[string]any {
	var expected, delivered, inWindow, boundary, duplicates, invalid, failedDials, planned, unexpected, unrecovered int
	var latencies, recovery []int64
	accepted := 0
	for _, sent := range published[warmup:] {
		if !sent.IsZero() {
			accepted++
		}
	}
	byRoom := orderedPublications(published, warmup, o.rooms)

	for _, c := range clients {
		duplicates += c.duplicates
		invalid += c.invalid
		for _, failed := range c.connectErrors {
			if !failed.Before(start) && failed.Before(end) {
				failedDials++
			}
		}
		for _, r := range c.reconnects {
			if r.down.Before(start) || !r.down.Before(end) {
				continue
			}
			if r.planned {
				planned++
			} else {
				unexpected++
			}
			if r.up.IsZero() {
				unrecovered++
			} else {
				recovery = append(recovery, r.up.Sub(r.down).Microseconds())
			}
		}
		windowIndex := 0
		for _, seq := range byRoom[c.room] {
			sent := published[seq]
			for windowIndex < len(c.windows) && !sent.Before(c.windows[windowIndex].end) {
				windowIndex++
			}
			us := c.deliveryUS[seq/o.rooms]
			if windowIndex >= len(c.windows) ||
				sent.Before(c.windows[windowIndex].begin.Add(o.guard)) ||
				!sent.Before(c.windows[windowIndex].end.Add(-o.guard)) {
				if us > 0 {
					boundary++
				}
				continue
			}
			expected++
			if us > 0 {
				delivered++
				if sent.Add(time.Duration(us) * time.Microsecond).Before(end) {
					inWindow++
				}
				latencies = append(latencies, us)
			}
		}
	}
	return map[string]any{
		"clients": o.clients, "rooms": o.rooms, "offered_publications_per_s": o.rate,
		"seed": o.seed, "warmup_s": o.warmup.Seconds(), "duration_s": o.duration.Seconds(),
		"guard_ms": o.guard.Milliseconds(), "drain_s": o.drain.Seconds(),
		"min_lifetime_s": o.low.Seconds(), "max_lifetime_s": o.high.Seconds(),
		"accepted_publications": accepted, "expected_deliveries": expected,
		"unique_deliveries": delivered, "missing_deliveries": expected - delivered,
		"received_outside_eligible_windows": boundary, "duplicates": duplicates, "invalid_or_misrouted": invalid,
		"delivered_before_window_end": inWindow, "delivered_during_drain": delivered - inWindow,
		"delivered_per_s":     float64(inWindow) / o.duration.Seconds(),
		"delivery_latency_ms": quantiles(latencies), "failed_connection_attempts": failedDials,
		"planned_disconnects": planned, "unexpected_disconnects": unexpected, "reconnects_completed": len(recovery),
		"reconnects_incomplete": unrecovered, "reconnect_latency_ms": quantiles(recovery),
	}
}

func quantiles(us []int64) any {
	if len(us) == 0 {
		return nil
	}
	slices.Sort(us)
	quantile := func(percent int) float64 { return float64(us[(percent*len(us)+99)/100-1]) / 1000 }
	return map[string]float64{"p50": quantile(50), "p95": quantile(95), "p99": quantile(99), "max": quantile(100)}
}
