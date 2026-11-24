package server

import (
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
)

const (
	statusReleased  = "Released"
	statusScheduled = "Scheduled"
	secondsPerMin   = 60
	minPerHour      = 60
	topicTitles     = 3
)

// shapeError means the catalog answered an item in a form this server does not know.
type shapeError struct{ reason string }

func (e *shapeError) Error() string { return e.reason }

// Item is one catalog result with the fields this server computes with checked.
type Item struct {
	raw       map[string]any
	published string
	sessions  []string
	score     float64
}

func newItem(raw map[string]any) (Item, error) {
	item := Item{raw: raw}
	if truthy(raw["publication_date"]) {
		text, ok := raw["publication_date"].(string)
		if !ok {
			return item, &shapeError{"publication_date is not text"}
		}
		item.published = text
	}
	sessions, err := sessionList(raw["live_event_start_dates"])
	if err != nil {
		return item, err
	}
	item.sessions = sessions
	item.score, err = scoreOf(raw["relevance_score"])
	return item, err
}

func sessionList(value any) ([]string, error) {
	if !truthy(value) {
		return nil, nil
	}
	list, ok := value.([]any)
	if !ok {
		return nil, &shapeError{"live_event_start_dates is not a list"}
	}
	sessions := make([]string, 0, len(list))
	for _, entry := range list {
		text, isText := entry.(string)
		if !isText {
			return nil, &shapeError{"a session date is not text"}
		}
		sessions = append(sessions, text)
	}
	return sessions, nil
}

func scoreOf(value any) (float64, error) {
	switch v := value.(type) {
	case nil:
		return 0, nil
	case json.Number:
		return v.Float64()
	case float64:
		return v, nil
	default:
		return 0, &shapeError{"relevance_score is not a number"}
	}
}

// parseItems checks each raw catalog item.
func parseItems(raw []map[string]any) ([]Item, error) {
	items := make([]Item, 0, len(raw))
	for _, one := range raw {
		item, err := newItem(one)
		if err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, nil
}

func (i Item) get(key string) any { return i.raw[key] }

// authors are the item's author values; a field that is not a list has none.
func (i Item) authors() []any { return asList(i.raw["authors"]) }

func asList(value any) []any {
	list, _ := value.([]any)
	return list
}

// isLive is true for an item with live event session dates.
func (i Item) isLive() bool { return len(i.sessions) > 0 }

// sessionsFrom are the live event session dates on or after today, soonest first.
func (i Item) sessionsFrom(today string) []string {
	var upcoming []string
	for _, day := range i.sessions {
		if day >= today {
			upcoming = append(upcoming, day)
		}
	}
	sort.Strings(upcoming)
	return upcoming
}

// status is Scheduled when the item's own date is after today (a live event: has a session from
// today on).
func (i Item) status(today string) string {
	if i.isLive() {
		if len(i.sessionsFrom(today)) > 0 {
			return statusScheduled
		}
		return statusReleased
	}
	published := i.published
	if len(published) > len(dayLayout) {
		published = published[:len(dayLayout)]
	}
	if published != "" && published > today {
		return statusScheduled
	}
	return statusReleased
}

// key identifies an item: its url, else its title.
func (i Item) key() string {
	for _, field := range []string{"url", "title"} {
		if truthy(i.raw[field]) {
			encoded, _ := encodeJSON(i.raw[field])
			return field + encoded
		}
	}
	return ""
}

// Entry is one result item as the model reads it: the catalog's own values plus the status.
type Entry struct {
	Title               any    `json:"title"`
	Authors             any    `json:"authors"`
	Format              any    `json:"format"`
	PublicationDate     string `json:"publication_date"`
	LiveEventStartDates any    `json:"live_event_start_dates,omitempty"`
	PageCount           any    `json:"page_count,omitempty"`
	Duration            any    `json:"duration,omitempty"`
	Status              string `json:"status"`
	URL                 any    `json:"url"`

	sortKey string
}

func orEmpty(value any) any {
	if truthy(value) {
		return value
	}
	return nil
}

// shape is one result item: the catalog's own values plus the status label.
func shape(item Item, today string) Entry {
	authors := item.get("authors")
	if !truthy(authors) {
		authors = []any{}
	}
	format := item.get("marketing_type")
	if !truthy(format) {
		format = item.get("display_format")
	}
	entry := Entry{
		Title: item.get("title"), Authors: authors, Format: format, PublicationDate: item.published,
		LiveEventStartDates: orEmpty(item.get("live_event_start_dates")), PageCount: orEmpty(item.get("page_count")),
		Status: item.status(today), URL: item.get("url"),
	}
	if truthy(item.get("duration")) {
		entry.Duration = humanDuration(item.get("duration"))
	}
	entry.sortKey = item.published
	if upcoming := item.sessionsFrom(today); len(upcoming) > 0 {
		entry.sortKey = upcoming[0]
	}
	return entry
}

// humanDuration is the catalog's duration in seconds as "10 h 31 min"; any other value is
// returned unchanged.
func humanDuration(value any) any {
	var seconds float64
	switch v := value.(type) {
	case json.Number:
		parsed, err := v.Float64()
		if err != nil {
			return value
		}
		seconds = parsed
	case float64:
		seconds = v
	case int:
		seconds = float64(v)
	default:
		return value
	}
	if seconds < 0 {
		return value
	}
	if seconds < secondsPerMin {
		return fmt.Sprintf("%d s", int(seconds))
	}
	minutes := int(seconds/secondsPerMin + 0.5)
	hours, minutes := minutes/minPerHour, minutes%minPerHour
	switch {
	case hours > 0 && minutes > 0:
		return fmt.Sprintf("%d h %d min", hours, minutes)
	case hours > 0:
		return fmt.Sprintf("%d h", hours)
	default:
		return strconv.Itoa(minutes) + " min"
	}
}

// ordered splits the items into the released, newest first, and the scheduled, soonest first.
func ordered(items []Item, today string) ([]Entry, []Entry) {
	released, scheduled := []Entry{}, []Entry{}
	for _, item := range items {
		entry := shape(item, today)
		if entry.Status == statusReleased {
			released = append(released, entry)
		} else {
			scheduled = append(scheduled, entry)
		}
	}
	sort.SliceStable(released, func(a, b int) bool { return released[a].PublicationDate > released[b].PublicationDate })
	sort.SliceStable(scheduled, func(a, b int) bool { return scheduled[a].sortKey < scheduled[b].sortKey })
	return released, scheduled
}

// mergeUnique is both lists, an item once by its key.
func mergeUnique(first, second []Item) []Item {
	seen := map[string]bool{}
	merged := make([]Item, 0, len(first)+len(second))
	for _, item := range append(append([]Item{}, first...), second...) {
		if !seen[item.key()] {
			seen[item.key()] = true
			merged = append(merged, item)
		}
	}
	return merged
}

func filterItems(items []Item, keep func(Item) bool) []Item {
	kept := make([]Item, 0, len(items))
	for _, item := range items {
		if keep(item) {
			kept = append(kept, item)
		}
	}
	return kept
}

// common are the most common string values of a field, or of each entry of a list field; other
// values are skipped. Ties go to the smaller text.
func common(items []Item, field string, limit int) []any {
	counts := map[string]int{}
	for _, item := range items {
		values := []any{item.get(field)}
		if list, ok := item.get(field).([]any); ok {
			values = list
		}
		for _, value := range values {
			if text, ok := value.(string); ok && text != "" {
				counts[text]++
			}
		}
	}
	texts := make([]string, 0, len(counts))
	for text := range counts {
		texts = append(texts, text)
	}
	sort.Slice(texts, func(a, b int) bool {
		if counts[texts[a]] != counts[texts[b]] {
			return counts[texts[a]] > counts[texts[b]]
		}
		return texts[a] < texts[b]
	})
	if len(texts) > limit {
		texts = texts[:limit]
	}
	out := make([]any, 0, len(texts))
	for _, text := range texts {
		out = append(out, text)
	}
	return out
}

// topicsOf is what the items are about: their most common tags, then the first titles (tags are
// often empty).
func topicsOf(items []Item, limit int) []any {
	topics := common(items, "tags", limit)
	titles := 0
	for _, item := range items {
		if truthy(item.get("title")) && titles < topicTitles {
			topics = append(topics, item.get("title"))
			titles++
		}
	}
	return topics
}

// sortByScore puts the best match first; equal scores keep the catalog's order.
func sortByScore(items []Item) {
	sort.SliceStable(items, func(a, b int) bool { return items[a].score > items[b].score })
}
