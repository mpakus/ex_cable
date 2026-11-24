package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"slices"
	"sync"
	"time"
)

type publication struct {
	scheduled, sent, completed time.Time
	accepted                   bool
}

func httpPublisher(concurrency int) *http.Client {
	return &http.Client{Timeout: 2 * time.Second, Transport: &http.Transport{
		MaxIdleConns: concurrency, MaxIdleConnsPerHost: concurrency, MaxConnsPerHost: concurrency,
	}}
}

func publish(o options, start time.Time, warmup, total int, measuredStart, measuredEnd time.Time) []publication {
	httpClient := httpPublisher(o.publishers)
	defer httpClient.CloseIdleConnections()

	log.Printf("Publishing %d events, %d events/s scheduled, %d publishers", total, o.rate, o.publishers)
	requests := make([]publication, total)
	send := func(seq int) {
		req := &requests[seq]
		deadline := measuredEnd
		if seq < warmup {
			deadline = measuredStart
		}
		now := time.Now()
		if o.publishers > 1 && !now.Before(deadline) {
			return
		}
		req.sent = now
		req.accepted = put(httpClient, o, seq, broadcastBody(seq%o.rooms, seq, now))
		req.completed = time.Now()
	}

	jobs := make(chan int, o.publishers)
	var workers sync.WaitGroup
	if o.publishers > 1 {
		for range o.publishers {
			workers.Go(func() {
				for seq := range jobs {
					send(seq)
				}
			})
		}
	}

	dispatch := func(seq, slot int) {
		scheduled := start.Add(time.Duration(slot) * time.Second / time.Duration(o.rate))
		time.Sleep(time.Until(scheduled))
		requests[seq].scheduled = scheduled
		if o.publishers == 1 {
			send(seq)
		} else {
			select {
			case jobs <- seq:
			default:
			}
		}
	}
	scheduleBursts(0, warmup, o.rooms, o.burst, dispatch)
	scheduleBursts(warmup, total, o.rooms, o.burst, dispatch)
	close(jobs)
	workers.Wait()
	return requests
}

// Sequence numbers still identify rooms by seq % rooms. Visit one room at a
// time within each block so the same socket can have several frames ready.
func scheduleBursts(first, end, rooms, burst int, dispatch func(seq, slot int)) {
	slot := first
	for base := first; base < end; base += rooms * burst {
		limit := min(end, base+rooms*burst)
		for room := base; room < min(base+rooms, limit); room++ {
			start := slot
			for seq := room; seq < limit; seq += rooms {
				dispatch(seq, start)
				slot++
			}
		}
	}
}

func runIngress(o options) error {
	h := httpPublisher(o.publishers)
	defer h.CloseIdleConnections()
	start := time.Now().Add(o.warmup)
	end := start.Add(o.duration)
	body := broadcastBody(0, 0, start)
	results := make([][]publication, o.publishers)
	var workers sync.WaitGroup
	log.Printf("HTTP-only workload with %d persistent publishers", o.publishers)
	for lane := range o.publishers {
		workers.Go(func() {
			for now := time.Now(); now.Before(end); now = time.Now() {
				accepted := put(h, o, lane, body)
				if !now.Before(start) {
					results[lane] = append(results[lane], publication{
						sent: now, completed: time.Now(), accepted: accepted,
					})
				}
			}
		})
	}
	workers.Wait()

	var records []publication
	for _, lane := range results {
		records = append(records, lane...)
	}
	out := map[string]any{
		"publishers": o.publishers, "warmup_s": o.warmup.Seconds(), "duration_s": o.duration.Seconds(),
		"measuring_from": start.Format(time.RFC3339Nano), "measuring_to": end.Format(time.RFC3339Nano),
	}
	summarizeHTTP(out, records, end, o.duration)
	return json.NewEncoder(os.Stdout).Encode(out)
}

func summarizeHTTP(out map[string]any, records []publication, end time.Time, duration time.Duration) {
	var skipped, failed, accepted, inWindow int
	var latency, lag []int64
	for _, req := range records {
		if req.sent.IsZero() {
			skipped++
			continue
		}
		if !req.scheduled.IsZero() {
			lag = append(lag, req.sent.Sub(req.scheduled).Microseconds())
		}
		if !req.accepted {
			failed++
			continue
		}
		accepted++
		latency = append(latency, req.completed.Sub(req.sent).Microseconds())
		if !req.completed.After(end) {
			inWindow++
		}
	}
	out["attempted_publications"] = len(records) - skipped
	out["skipped_publications"] = skipped
	out["publish_errors"] = failed
	out["accepted_publications"] = accepted
	out["accepted_before_window_end"] = inWindow
	out["accepted_http_per_s"] = float64(inWindow) / duration.Seconds()
	out["http_latency_ms"] = quantiles(latency)
	out["schedule_lag_ms"] = quantiles(lag)
}

func orderedPublications(sent []time.Time, warmup, rooms int) [][]int {
	byRoom := make([][]int, rooms)
	for seq := warmup; seq < len(sent); seq++ {
		if !sent[seq].IsZero() {
			room := seq % rooms
			byRoom[room] = append(byRoom[room], seq)
		}
	}
	for _, room := range byRoom {
		slices.SortStableFunc(room, func(a, b int) int { return sent[a].Compare(sent[b]) })
	}
	return byRoom
}
