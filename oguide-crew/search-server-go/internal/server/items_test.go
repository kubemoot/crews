package server

import (
	"encoding/json"
	"strings"
	"testing"
)

func mustItem(t *testing.T, raw m) Item {
	t.Helper()
	item, err := newItem(raw)
	if err != nil {
		t.Fatalf("newItem: %v", err)
	}
	return item
}

func items(t *testing.T, raws ...m) []Item {
	t.Helper()
	out := make([]Item, 0, len(raws))
	for _, raw := range raws {
		out = append(out, mustItem(t, raw))
	}
	return out
}

func TestStatus(t *testing.T) {
	cases := []struct {
		name string
		item m
		want string
	}{
		{"published today is released", book("T", "2026-10-20"), statusReleased},
		{"published yesterday is released", book("T", "2026-10-19"), statusReleased},
		{"published tomorrow is scheduled", book("T", "2026-10-21"), statusScheduled},
		{"a timestamp uses its date part", book("T", "2026-10-21T00:00:00Z"), statusScheduled},
		{"an item without a date is released", book("T", ""), statusReleased},
		{"a live event with a session today is scheduled", event("E", []string{"2026-10-19", "2026-10-20"}),
			statusScheduled},
		{"a live event whose sessions are past is released", event("E", []string{"2026-10-19"}), statusReleased},
		{"the label ignores the publication date of an event",
			event("E", []string{"2026-12-01"}, m{"publication_date": "2026-01-01"}), statusScheduled},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			equal(t, c.want, mustItem(t, c.item).status(today))
		})
	}
}

func TestOrderedReleasedNewestFirstAndScheduledSoonestFirst(t *testing.T) {
	released, scheduled := ordered(items(t, book("Old", "2020-01-01"), book("Next", "2027-02-25"),
		book("New", "2026-09-01"), book("Soon", "2026-10-27"), event("Later", []string{"2026-12-11"}),
		event("Sooner", []string{"2026-10-22"})), today)
	equal(t, []string{"New", "Old"}, entryTitles(released))
	equal(t, []string{"Sooner", "Soon", "Later", "Next"}, entryTitles(scheduled))
}

func entryTitles(entries []Entry) []string {
	out := make([]string, 0, len(entries))
	for _, entry := range entries {
		out = append(out, entry.Title.(string))
	}
	return out
}

func TestAnEventSortsByItsNextSessionNotAPastOne(t *testing.T) {
	_, scheduled := ordered(items(t, event("Two", []string{"2026-10-01", "2026-12-01"}),
		event("One", []string{"2026-11-01"})), today)
	equal(t, []string{"One", "Two"}, entryTitles(scheduled))
}

func TestEqualDatesKeepTheCatalogOrder(t *testing.T) {
	released, _ := ordered(items(t, book("First", "2020-01-01"), book("Second", "2020-01-01"),
		book("Third", "2020-01-01")), today)
	equal(t, []string{"First", "Second", "Third"}, entryTitles(released))
}

func TestAnItemKeepsTheCatalogValuesAndGetsAStatus(t *testing.T) {
	shaped := decoded(t, shape(mustItem(t, book("T", "2026-01-01", m{"unknown_field": "x"})), today))
	keys := make([]string, 0, len(shaped))
	for key := range shaped {
		keys = append(keys, key)
	}
	equal(t, 7, len(keys), "the shaped item has seven fields")
	for _, want := range []string{"title", "authors", "format", "publication_date", "page_count", "status", "url"} {
		isTrue(t, shaped[want] != nil, want)
	}
	equal(t, "book", shaped["format"])
}

func TestAShapedItemWritesItsFieldsInTheCatalogReadingOrder(t *testing.T) {
	text, err := encodeJSON(shape(mustItem(t, event("E", []string{"2026-11-01"})), today))
	if err != nil {
		t.Fatal(err)
	}
	last := -1
	for _, key := range []string{`"title"`, `"authors"`, `"format"`, `"publication_date"`, `"live_event_start_dates"`,
		`"status"`, `"url"`} {
		at := strings.Index(text, key)
		isTrue(t, at > last, key+" comes after the one before it")
		last = at
	}
}

func TestSecondsBecomeHoursAndMinutes(t *testing.T) {
	cases := map[int]string{37854: "10 h 31 min", 3600: "1 h", 2700: "45 min", 7260: "2 h 1 min", 30: "30 s",
		59: "59 s", 60: "1 min"}
	for seconds, want := range cases {
		equal(t, want, humanDuration(json.Number(jsonInt(seconds))), jsonInt(seconds))
	}
}

func jsonInt(n int) string {
	text, _ := json.Marshal(n)
	return string(text)
}

func TestAValueThatIsNotSecondsIsReturnedAsIs(t *testing.T) {
	for _, value := range []any{"10h", nil, true, json.Number("-5"), json.Number("abc")} {
		equal(t, value, humanDuration(value))
	}
}

func TestARecordedCourseShowsNoRawSeconds(t *testing.T) {
	course := m{"title": "Course", "authors": list("A. Author"), "marketing_type": "course",
		"duration": json.Number("37854"), "publication_date": "2025-01-01", "url": "u"}
	text, _ := encodeJSON(shape(mustItem(t, course), today))
	contains(t, text, `"duration":"10 h 31 min"`)
	isTrue(t, !strings.Contains(text, "37854"), "no raw seconds")
}

func TestAnItemWithoutDurationHasNoDurationField(t *testing.T) {
	text, _ := encodeJSON(shape(mustItem(t, book("B", "2020-01-01")), today))
	isTrue(t, !strings.Contains(text, "duration"), "no duration field")
}

func TestAnItemWithOddFieldTypesIsAShapeError(t *testing.T) {
	for _, raw := range []m{{"publication_date": json.Number("20260101")}, {"live_event_start_dates": "2026-01-01"},
		{"live_event_start_dates": []any{5}}, {"relevance_score": "high"}} {
		_, err := newItem(raw)
		isTrue(t, err != nil, "an item with odd field types is refused")
	}
}

func TestMergeUniqueKeepsAnItemOnceByItsURL(t *testing.T) {
	first := items(t, book("A", "2020-01-01"), book("B", "2020-01-01"))
	second := items(t, book("B", "2020-01-01"), book("C", "2020-01-01"))
	equal(t, 3, len(mergeUnique(first, second)))
}

func TestMergeUniqueFallsBackToTheTitleWhenThereIsNoURL(t *testing.T) {
	first := items(t, m{"title": "A"}, m{"title": "A"})
	equal(t, 1, len(mergeUnique(first, nil)))
}

func TestEncodingKeepsAngleBracketsAndAmpersands(t *testing.T) {
	text, _ := encodeJSON(newObj().set("t", "<b> & </b>"))
	equal(t, `{"t":"<b> & </b>"}`, text)
}

func TestTruthyFollowsTheEmptyValueRule(t *testing.T) {
	for _, empty := range []any{nil, false, "", json.Number("0"), 0, 0.0, []any{}, m{}} {
		isTrue(t, !truthy(empty), "empty")
	}
	for _, full := range []any{true, "x", json.Number("5"), 1, []any{1}, m{"a": 1}} {
		isTrue(t, truthy(full), "full")
	}
}

func TestOrderedObjectsKeepTheirKeysInOrderAndAnExistingKeyKeepsItsPlace(t *testing.T) {
	o := newObj().set("b", 1).set("a", 2).set("b", 3)
	text, _ := encodeJSON(o)
	equal(t, `{"b":3,"a":2}`, text)
}
