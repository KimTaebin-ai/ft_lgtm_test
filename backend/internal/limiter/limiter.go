// Package limiter는 동시 처리 수 제한과 대기열이다.
// 처리 슬롯(채널)과 대기 카운터로 구성되며, 대기열이 가득 차면 기다리지 않고 즉시 거절한다.
package limiter

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"time"
)

var (
	// ErrFull은 처리 슬롯과 대기열이 모두 찼음을 뜻한다 (즉시 반환).
	ErrFull = errors.New("queue full")
	// ErrWaitTimeout은 대기 상한 시간 안에 슬롯을 얻지 못했음을 뜻한다.
	ErrWaitTimeout = errors.New("queue wait timeout")
)

type Limiter struct {
	slots      chan struct{}
	maxWaiting int32
	maxWait    time.Duration
	waiting    atomic.Int32
}

// New는 동시 처리 active개, 대기 waiting개, 대기 상한 시간 maxWait의 Limiter를 만든다.
func New(active, waiting int, maxWait time.Duration) *Limiter {
	return &Limiter{slots: make(chan struct{}, active), maxWaiting: int32(waiting), maxWait: maxWait}
}

// Acquire는 슬롯을 얻을 때까지 기다린다. 반환된 release는 처리가 끝나면 반드시 한 번 호출해야 한다 (여러 번 호출해도 안전).
// 대기 중 ctx가 취소되면(클라이언트가 끊김) 대기열에서 빠지고 자리가 바로 반환되며 ctx.Err()를 돌려준다.
// wait는 슬롯을 얻기까지 걸린 시간이다 (바로 얻으면 0).
func (l *Limiter) Acquire(ctx context.Context) (release func(), wait time.Duration, err error) {
	select {
	case l.slots <- struct{}{}:
		return l.releaseFn(), 0, nil
	default:
	}
	// 대기열 자리를 먼저 예약한다. 가득 차 있으면 기다리지 않고 거절한다.
	for {
		n := l.waiting.Load()
		if n >= l.maxWaiting {
			return nil, 0, ErrFull
		}
		if l.waiting.CompareAndSwap(n, n+1) {
			break
		}
	}
	defer l.waiting.Add(-1)

	start := time.Now()
	t := time.NewTimer(l.maxWait)
	defer t.Stop()
	select {
	case l.slots <- struct{}{}:
		return l.releaseFn(), time.Since(start), nil
	case <-ctx.Done():
		return nil, time.Since(start), ctx.Err()
	case <-t.C:
		return nil, time.Since(start), ErrWaitTimeout
	}
}

func (l *Limiter) releaseFn() func() {
	var once sync.Once
	return func() { once.Do(func() { <-l.slots }) }
}

// Active는 처리 중인 요청 수다.
func (l *Limiter) Active() int { return len(l.slots) }

// Waiting은 대기 중인 요청 수다.
func (l *Limiter) Waiting() int { return int(l.waiting.Load()) }
