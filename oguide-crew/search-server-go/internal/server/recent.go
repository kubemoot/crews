package server

import (
	"strings"
	"sync"
	"time"
)

const (
	repeatWindow  = 20 * time.Second
	maxRemembered = 256
)

// repeatNote tells the model that a repeated search was answered from memory.
const repeatNote = "This repeats an identical search run moments ago in this thread, so these are the same " +
	"results as before; search with different keywords for anything new."

type remembered struct {
	at     time.Time
	result *obj
}

// Recent remembers successful searches and their results for a short while, so a repeat is
// answered from memory, whichever caller of the thread made the first search. It holds at most
// max searches (the oldest go first) however many distinct searches arrive.
type Recent struct {
	mu     sync.Mutex
	clock  func() time.Time
	window time.Duration
	max    int
	order  []string
	seen   map[string]remembered
}

// NewRecent is a store with the given clock, window and size.
func NewRecent(clock func() time.Time, window time.Duration, maxEntries int) *Recent {
	return &Recent{clock: clock, window: window, max: maxEntries, seen: map[string]remembered{}}
}

func (r *Recent) prune() {
	now := r.clock()
	kept := r.order[:0]
	for _, key := range r.order {
		if now.Sub(r.seen[key].at) < r.window {
			kept = append(kept, key)
		} else {
			delete(r.seen, key)
		}
	}
	r.order = kept
}

// earlier is the result of the same search run within the window, or nil.
func (r *Recent) earlier(key string) *obj {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.prune()
	if entry, found := r.seen[key]; found {
		return entry.result
	}
	return nil
}

func (r *Recent) remember(key string, result *obj) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.prune()
	if _, found := r.seen[key]; found {
		r.drop(key)
	}
	r.order = append(r.order, key)
	r.seen[key] = remembered{at: r.clock(), result: result}
	for len(r.order) > r.max {
		delete(r.seen, r.order[0])
		r.order = r.order[1:]
	}
}

func (r *Recent) drop(key string) {
	delete(r.seen, key)
	for i, other := range r.order {
		if other == key {
			r.order = append(r.order[:i], r.order[i+1:]...)
			return
		}
	}
}

func (r *Recent) size() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.order)
}

// callKey is the identity of a search: the thread (and the person, when the call names one), the
// tool, and the argument.
func callKey(name, value string, meta any) string {
	fields, _ := meta.(map[string]any)
	thread := ""
	for _, key := range []string{"threadId", keyConversationID} {
		if truthy(fields[key]) {
			thread = pyStr(fields[key])
			break
		}
	}
	person := ""
	if truthy(fields[keyPrincipalID]) {
		person = pyStr(fields[keyPrincipalID])
	}
	return strings.Join([]string{thread, person, name, strings.ToLower(strings.Join(strings.Fields(value), " "))}, "\x00")
}
