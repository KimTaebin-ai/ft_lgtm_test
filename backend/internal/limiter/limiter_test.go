package limiter

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

func acquire(t *testing.T, l *Limiter) func() {
	t.Helper()
	rel, _, err := l.Acquire(context.Background())
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	return rel
}

// waitFor는 cond가 참이 될 때까지 최대 2초 기다린다.
func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	for i := 0; i < 200; i++ {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timeout waiting for %s", what)
}

func TestImmediateWhenFree(t *testing.T) {
	l := New(2, 8, time.Second)
	_, wait, err := l.Acquire(context.Background())
	if err != nil || wait != 0 {
		t.Fatalf("err=%v wait=%v", err, wait)
	}
	if l.Active() != 1 || l.Waiting() != 0 {
		t.Fatalf("active=%d waiting=%d", l.Active(), l.Waiting())
	}
}

// 처리 2 + 대기 8 이 차면 나머지는 기다리지 않고 ErrFull.
func TestRejectsBeyondCapacityImmediately(t *testing.T) {
	l := New(2, 8, time.Minute)
	var rels [2]func()
	for i := range rels {
		rels[i] = acquire(t, l)
	}
	var wg sync.WaitGroup
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, _, _ = l.Acquire(ctx) }()
	}
	waitFor(t, "8 waiting", func() bool { return l.Waiting() == 8 })

	start := time.Now()
	_, _, err := l.Acquire(context.Background())
	if !errors.Is(err, ErrFull) {
		t.Fatalf("err=%v, want ErrFull", err)
	}
	if d := time.Since(start); d > 100*time.Millisecond {
		t.Fatalf("rejection took %v", d)
	}
	cancel()
	wg.Wait()
}

// 대기 중 취소하면 자리가 반환되어 새 요청이 대기열에 들어간다.
func TestCancelWhileWaitingFreesSeat(t *testing.T) {
	l := New(1, 1, time.Minute)
	rel := acquire(t, l)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { _, _, err := l.Acquire(ctx); done <- err }()
	waitFor(t, "1 waiting", func() bool { return l.Waiting() == 1 })
	if _, _, err := l.Acquire(context.Background()); !errors.Is(err, ErrFull) {
		t.Fatalf("err=%v, want ErrFull", err)
	}
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("err=%v, want Canceled", err)
	}
	if l.Waiting() != 0 || l.Active() != 1 {
		t.Fatalf("active=%d waiting=%d", l.Active(), l.Waiting())
	}
	go func() { _, _, _ = l.Acquire(context.Background()) }()
	waitFor(t, "re-queued", func() bool { return l.Waiting() == 1 })
	rel()
}

func TestWaitTimeout(t *testing.T) {
	l := New(1, 1, 50*time.Millisecond)
	acquire(t, l)
	_, wait, err := l.Acquire(context.Background())
	if !errors.Is(err, ErrWaitTimeout) {
		t.Fatalf("err=%v, want ErrWaitTimeout", err)
	}
	if wait < 50*time.Millisecond {
		t.Fatalf("wait=%v", wait)
	}
	if l.Waiting() != 0 {
		t.Fatalf("waiting=%d", l.Waiting())
	}
}

func TestReleaseHandsSlotToWaiterAndIsIdempotent(t *testing.T) {
	l := New(1, 1, time.Minute)
	rel := acquire(t, l)
	got := make(chan time.Duration, 1)
	go func() { _, w, _ := l.Acquire(context.Background()); got <- w }()
	waitFor(t, "waiting", func() bool { return l.Waiting() == 1 })
	rel()
	rel()
	select {
	case w := <-got:
		if w <= 0 {
			t.Fatalf("wait=%v, want > 0", w)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("waiter not admitted")
	}
	if l.Active() != 1 {
		t.Fatalf("active=%d, want 1 (double release must not free the waiter's slot)", l.Active())
	}
}

func TestActiveNeverExceedsLimit(t *testing.T) {
	l := New(2, 100, time.Minute)
	var mu sync.Mutex
	cur, peak := 0, 0
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			rel, _, err := l.Acquire(context.Background())
			if err != nil {
				t.Error(err)
				return
			}
			mu.Lock()
			cur++
			if cur > peak {
				peak = cur
			}
			mu.Unlock()
			time.Sleep(2 * time.Millisecond)
			mu.Lock()
			cur--
			mu.Unlock()
			rel()
		}()
	}
	wg.Wait()
	if peak > 2 {
		t.Fatalf("peak=%d", peak)
	}
}
