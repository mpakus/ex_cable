package main

import (
	"reflect"
	"testing"
	"time"
)

func TestBurstScheduleKeepsRoomsAndPartialPhases(t *testing.T) {
	for _, trial := range []struct {
		first, end, rooms, burst int
		want                     [][2]int
	}{
		{3, 8, 2, 1, [][2]int{{3, 3}, {4, 4}, {5, 5}, {6, 6}, {7, 7}}},
		{3, 13, 2, 4, [][2]int{{3, 3}, {5, 3}, {7, 3}, {9, 3}, {4, 7}, {6, 7}, {8, 7}, {10, 7}, {11, 11}, {12, 12}}},
		{0, 0, 3, 4, nil},
	} {
		var got [][2]int
		scheduleBursts(trial.first, trial.end, trial.rooms, trial.burst, func(seq, slot int) {
			got = append(got, [2]int{seq, slot})
		})
		if !reflect.DeepEqual(got, trial.want) {
			t.Fatalf("schedule = %v, want %v", got, trial.want)
		}
	}
}

func TestSummarizeHTTPCountsAcceptedBeforeDeadline(t *testing.T) {
	start := time.Unix(100, 0)
	end := start.Add(time.Second)
	records := []publication{
		{scheduled: start, sent: start.Add(time.Millisecond), completed: start.Add(3 * time.Millisecond), accepted: true},
		{scheduled: start, sent: start.Add(2 * time.Millisecond), completed: end.Add(time.Millisecond), accepted: true},
		{scheduled: start, sent: start.Add(2 * time.Millisecond), completed: start.Add(3 * time.Millisecond)},
		{scheduled: start},
	}

	out := map[string]any{}
	summarizeHTTP(out, records, end, time.Second)
	for key, want := range map[string]int{
		"attempted_publications": 3, "skipped_publications": 1, "publish_errors": 1,
		"accepted_publications": 2, "accepted_before_window_end": 1,
	} {
		if out[key] != want {
			t.Errorf("%s = %v, want %d", key, out[key], want)
		}
	}
	if got := out["accepted_http_per_s"]; got != 1.0 {
		t.Errorf("accepted_http_per_s = %v, want 1", got)
	}
}

func TestPublicationLedgerOrdersConcurrentSendsWithinEachRoom(t *testing.T) {
	start := time.Unix(100, 0)
	sent := []time.Time{
		start, start.Add(time.Second), start.Add(8 * time.Second), time.Time{},
		start.Add(2 * time.Second), start.Add(3 * time.Second), start.Add(4 * time.Second),
	}
	want := [][]int{{4, 6, 2}, {5}}
	if got := orderedPublications(sent, 2, 2); !reflect.DeepEqual(got, want) {
		t.Fatalf("ordered publications = %v, want %v", got, want)
	}
}
