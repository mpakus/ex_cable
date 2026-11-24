package main

import (
	"testing"
	"time"
)

func TestSummarizeDistinguishesMissedLateAndBoundaryDeliveries(t *testing.T) {
	start := time.Unix(100, 0)
	end := start.Add(time.Second)
	o := options{clients: 1, rooms: 1, duration: time.Second, guard: 100 * time.Millisecond}
	published := []time.Time{
		start.Add(50 * time.Millisecond),
		start.Add(220 * time.Millisecond),
		start.Add(500 * time.Millisecond),
		start.Add(900 * time.Millisecond),
	}
	clients := []client{{
		windows:    []window{{start.Add(100 * time.Millisecond), end.Add(time.Second)}},
		deliveryUS: []int64{1000, 2000, 0, 200000},
		duplicates: 2,
		reconnects: []reconnect{
			{down: start.Add(300 * time.Millisecond), up: start.Add(450 * time.Millisecond), planned: true},
			{down: start.Add(800 * time.Millisecond)},
		},
	}}

	got := summarize(o, clients, published, 0, start, end)
	for key, want := range map[string]int{
		"expected_deliveries": 3, "unique_deliveries": 2, "missing_deliveries": 1,
		"received_outside_eligible_windows": 1, "delivered_before_window_end": 1,
		"delivered_during_drain": 1, "duplicates": 2,
		"planned_disconnects": 1, "unexpected_disconnects": 1,
		"reconnects_completed": 1, "reconnects_incomplete": 1,
	} {
		if got[key] != want {
			t.Errorf("%s = %v, want %d", key, got[key], want)
		}
	}
	where := got["delivery_latency_ms"].(map[string]float64)
	if where["p50"] != 2 || where["p99"] != 200 {
		t.Errorf("unexpected latency percentiles: %v", where)
	}
}
