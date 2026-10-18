package ratelimit

import (
	"testing"
	"time"
)

func TestBucketBurstAndRefill(t *testing.T) {
	now := time.Unix(0, 0)
	b := NewBucket(2, 3, now)
	for i := 0; i < 3; i++ {
		if !b.Allow(now) {
			t.Fatalf("burst token %d denied", i)
		}
	}
	if b.Allow(now) {
		t.Fatal("allowed beyond burst")
	}
	if !b.Allow(now.Add(500 * time.Millisecond)) {
		t.Fatal("expected refill of one token after 0.5s at 2/s")
	}
	if b.Allow(now.Add(500 * time.Millisecond)) {
		t.Fatal("only one token should have refilled")
	}
	// Refill never exceeds burst.
	later := now.Add(time.Hour)
	for i := 0; i < 3; i++ {
		if !b.Allow(later) {
			t.Fatalf("token %d denied after long idle", i)
		}
	}
	if b.Allow(later) {
		t.Fatal("refill exceeded burst")
	}
}

func TestKeyedIsolationAndSweep(t *testing.T) {
	now := time.Unix(0, 0)
	k := NewKeyed(1, 1, time.Minute)
	if !k.Allow("a", now) || k.Allow("a", now) {
		t.Fatal("key a should allow exactly one")
	}
	if !k.Allow("b", now) {
		t.Fatal("key b must be independent of a")
	}
	k.Sweep(now.Add(2 * time.Minute))
	if len(k.buckets) != 0 {
		t.Fatalf("sweep left %d buckets", len(k.buckets))
	}
}
