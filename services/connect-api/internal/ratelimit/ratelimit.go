// Package ratelimit provides small in-memory token buckets.
package ratelimit

import (
	"sync"
	"time"
)

// Bucket is a token bucket. It is not safe for concurrent use; see Keyed.
type Bucket struct {
	rate   float64 // tokens per second
	burst  float64
	tokens float64
	last   time.Time
}

// NewBucket returns a full bucket.
func NewBucket(ratePerSecond float64, burst int, now time.Time) *Bucket {
	return &Bucket{rate: ratePerSecond, burst: float64(burst), tokens: float64(burst), last: now}
}

// Allow consumes one token if available.
func (b *Bucket) Allow(now time.Time) bool {
	if elapsed := now.Sub(b.last).Seconds(); elapsed > 0 {
		b.tokens += elapsed * b.rate
		if b.tokens > b.burst {
			b.tokens = b.burst
		}
		b.last = now
	}
	if b.tokens >= 1 {
		b.tokens--
		return true
	}
	return false
}

// Keyed holds one bucket per key (e.g. client IP) and forgets idle keys.
type Keyed struct {
	mu      sync.Mutex
	rate    float64
	burst   int
	idle    time.Duration
	buckets map[string]*keyedEntry
}

type keyedEntry struct {
	b    *Bucket
	seen time.Time
}

// NewKeyed creates a keyed limiter.
func NewKeyed(ratePerSecond float64, burst int, idle time.Duration) *Keyed {
	return &Keyed{rate: ratePerSecond, burst: burst, idle: idle, buckets: map[string]*keyedEntry{}}
}

// Allow consumes a token for key.
func (k *Keyed) Allow(key string, now time.Time) bool {
	k.mu.Lock()
	defer k.mu.Unlock()
	e, ok := k.buckets[key]
	if !ok {
		if len(k.buckets) > 50_000 {
			k.sweepLocked(now)
		}
		e = &keyedEntry{b: NewBucket(k.rate, k.burst, now)}
		k.buckets[key] = e
	}
	e.seen = now
	return e.b.Allow(now)
}

// Sweep removes keys idle for longer than the idle window.
func (k *Keyed) Sweep(now time.Time) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.sweepLocked(now)
}

func (k *Keyed) sweepLocked(now time.Time) {
	for key, e := range k.buckets {
		if now.Sub(e.seen) > k.idle {
			delete(k.buckets, key)
		}
	}
}
