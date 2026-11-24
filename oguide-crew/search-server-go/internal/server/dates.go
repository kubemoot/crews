package server

import (
	"strings"
	"time"
)

const dayLayout = "2006-01-02"

// loadZone is time.LoadLocation; a test swaps it to lose the zone database.
var loadZone = time.LoadLocation

// localLayouts are the ISO 8601 date-times whose date is the requester's local date.
var localLayouts = []string{
	"2006-01-02T15:04:05Z07:00", "2006-01-02T15:04:05", "2006-01-02T15:04Z07:00", "2006-01-02T15:04",
	"2006-01-02T15Z07:00", "2006-01-02T15",
	"2006-01-02 15:04:05Z07:00", "2006-01-02 15:04:05", "2006-01-02 15:04Z07:00", "2006-01-02 15:04",
}

// zoneNamed is the IANA zone with this name, or nil when the name is missing or unknown.
func zoneNamed(name any) *time.Location {
	text, ok := name.(string)
	text = strings.TrimSpace(text)
	if !ok || text == "" || text == "Local" {
		return nil
	}
	zone, err := loadZone(text)
	if err != nil {
		return nil
	}
	return zone
}

// dateNamed is the ISO date (YYYY-MM-DD) in this value, when it has one.
func dateNamed(value any) (string, bool) {
	text, ok := value.(string)
	text = strings.TrimSpace(text)
	if !ok || len(text) != len(dayLayout) {
		return "", false
	}
	day, err := time.Parse(dayLayout, text)
	if err != nil {
		return "", false
	}
	return day.Format(dayLayout), true
}

// localDateOf is the date of an ISO 8601 date-time on the requester's own clock, when it has one.
func localDateOf(value any) (string, bool) {
	text, ok := value.(string)
	text = strings.TrimSpace(text)
	if !ok || len(text) < len(dayLayout)+1 {
		return "", false
	}
	for _, layout := range localLayouts {
		if moment, err := time.Parse(layout, text); err == nil {
			return moment.Format(dayLayout), true
		}
	}
	return "", false
}

// resolveToday is the requester's date and where it came from: requestDate, localDateTime,
// timeZone, then the default zone. A value that is missing or malformed is skipped.
func resolveToday(meta any, defaultZone string, now time.Time) (string, string) {
	fields, _ := meta.(map[string]any)
	if day, ok := dateNamed(fields["requestDate"]); ok {
		return day, "the request date"
	}
	if day, ok := localDateOf(fields["localDateTime"]); ok {
		return day, "the request local time"
	}
	if zone := zoneNamed(fields["timeZone"]); zone != nil {
		return now.In(zone).Format(dayLayout), "the request time zone " + zone.String()
	}
	if zone := zoneNamed(defaultZone); zone != nil {
		return now.In(zone).Format(dayLayout), "the default time zone " + zone.String()
	}
	return now.UTC().Format(dayLayout), "the default time zone UTC"
}

// releaseRange is the date filter the catalog applies: items up to today, or items from today on.
func releaseRange(today string, released bool) map[string]any {
	if released {
		return map[string]any{"original_input": "released up to today",
			"normalized_description": "released up to " + today, "end_date": today, "confidence": 1}
	}
	return map[string]any{"original_input": "scheduled from today",
		"normalized_description": "scheduled from " + today, "start_date": today, "confidence": 1}
}
