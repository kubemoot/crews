package server

import (
	"errors"
	"testing"
	"time"
)

func call(t *testing.T, meta string, zone string, at time.Time) m {
	t.Helper()
	s := newServer(answers(), Config{DefaultZone: zone, Now: func() time.Time { return at }})
	reply := rpc(t, s, toolCall("find_released", `{"topic":"x"}`, meta))
	payload, failed := callText(t, reply)
	isTrue(t, !failed, "the call succeeds")
	return payload
}

func TestTheRequestDateWinsOverEverything(t *testing.T) {
	out := call(t, `{"requestDate":"2026-03-04","timeZone":"Asia/Tokyo"}`, "UTC", now)
	equal(t, "2026-03-04", out["today"])
	equal(t, "the request date", out["dateSource"])
}

func TestATimeZoneGivesTheDateInThatZone(t *testing.T) {
	evening := time.Date(2026, 10, 20, 20, 0, 0, 0, time.UTC)
	out := call(t, `{"timeZone":"Asia/Tokyo"}`, "UTC", evening)
	equal(t, "2026-10-21", out["today"])
	equal(t, "the request time zone Asia/Tokyo", out["dateSource"])
}

func TestARequestAt2330InLosAngelesIsStillThatDateAfterUTCRolledOver(t *testing.T) {
	late := time.Date(2026, 10, 21, 6, 30, 0, 0, time.UTC) // 23:30 PDT on the 20th
	equal(t, "2026-10-21", call(t, "", "UTC", late)["today"])
	equal(t, "2026-10-20", call(t, `{"timeZone":"America/Los_Angeles"}`, "UTC", late)["today"])
}

func TestWithoutMetaTheDefaultZoneIsUsedAndNamed(t *testing.T) {
	late := time.Date(2026, 10, 21, 6, 30, 0, 0, time.UTC)
	out := call(t, "", "America/New_York", late)
	equal(t, "2026-10-21", out["today"])
	equal(t, "the default time zone America/New_York", out["dateSource"])
}

func TestTheDefaultZoneIsUTCWhenNothingIsSet(t *testing.T) {
	out := call(t, "", "", now)
	equal(t, "2026-10-20", out["today"])
	equal(t, "the default time zone UTC", out["dateSource"])
}

func TestMalformedMetaValuesFallBack(t *testing.T) {
	for _, meta := range []string{`{"requestDate":"tomorrow"}`, `{"requestDate":20261020}`,
		`{"timeZone":"Mars/Base"}`, `{"timeZone":5}`, `{"requestDate":"2026-13-45"}`, `"not an object"`, `null`, `[]`,
		`{"timeZone":"Local"}`, `{"timeZone":"  "}`} {
		out := call(t, meta, "UTC", now)
		equal(t, "2026-10-20", out["today"], meta)
		equal(t, "the default time zone UTC", out["dateSource"], meta)
	}
}

func TestTheRequestersLocalDateTimeGivesTheirDate(t *testing.T) {
	out := call(t, `{"localDateTime":"2026-10-24T09:15:00","timeZone":"Asia/Tokyo"}`, "UTC", now)
	equal(t, "2026-10-24", out["today"])
	equal(t, "the request local time", out["dateSource"])
}

func TestLocalDateTimesInTheFormsISO8601Allows(t *testing.T) {
	for _, text := range []string{"2026-10-24T09:15:00", "2026-10-24T09:15", "2026-10-24 09:15:00",
		"2026-10-24T09:15:00.123456", "2026-10-24T09:15:00Z", "2026-10-24T09:15:00-07:00", "2026-10-24T09"} {
		day, ok := localDateOf(text)
		isTrue(t, ok, text)
		equal(t, "2026-10-24", day, text)
	}
}

func TestTheRequestDateStillWinsOverTheLocalDateTime(t *testing.T) {
	out := call(t, `{"requestDate":"2026-10-25","localDateTime":"2026-10-24T09:15:00"}`, "UTC", now)
	equal(t, "2026-10-25", out["today"])
}

func TestAnUnreadableLocalDateTimeFallsBackToTheTimeZone(t *testing.T) {
	evening := time.Date(2026, 10, 20, 20, 0, 0, 0, time.UTC)
	for _, bad := range []string{`"tomorrow"`, `"2026-10-24"`, `"2026-13-45T09:00:00"`, `5`, `""`, `null`, `[]`} {
		out := call(t, `{"localDateTime":`+bad+`,"timeZone":"Asia/Tokyo"}`, "UTC", evening)
		equal(t, "2026-10-21", out["today"], bad)
		equal(t, "the request time zone Asia/Tokyo", out["dateSource"], bad)
	}
}

func TestTheMetaKubemootSendsForACalifornianIsUsed(t *testing.T) {
	// 09:15 on the 24th in Los Angeles is already the 24th, 16:15, in UTC; the server clock is far later.
	meta := `{"timeZone":"America/Los_Angeles","localDateTime":"2026-10-24T09:15:00","requestDate":"2026-10-24"}`
	later := time.Date(2026, 11, 30, 3, 0, 0, 0, time.UTC)
	out := call(t, meta, "UTC", later)
	equal(t, "2026-10-24", out["today"])
	equal(t, "the request date", out["dateSource"])
}

func TestABadDefaultZoneFallsBackToUTC(t *testing.T) {
	equal(t, "the default time zone UTC", call(t, "", "Not/AZone", now)["dateSource"])
}

func TestTheDateIsNeverTakenFromTheArguments(t *testing.T) {
	s := newServer(answers(), Config{})
	payload, _ := callText(t, rpc(t, s, toolCall("find_released",
		`{"topic":"x","today":"1999-01-01","requestDate":"1999-01-01"}`, "")))
	equal(t, "2026-10-20", payload["today"])
}

func TestTheStatusLabelsFollowTheRequestersDate(t *testing.T) {
	catalog := answers([]m{book("B", "2026-10-21", m{"authors": list("N Nn")})})
	s := newServer(catalog, Config{})
	payload, _ := callText(t, rpc(t, s, toolCall("find_by_author", `{"name":"N Nn"}`, `{"requestDate":"2026-10-21"}`)))
	books, _ := payload["released_books"].([]any)
	equal(t, "Released", books[0].(m)["status"])
}

func TestAMissingTimeZoneDatabaseFallsBackToUTC(t *testing.T) {
	saved := loadZone
	loadZone = func(name string) (*time.Location, error) { return nil, errors.New("no zone " + name) }
	defer func() { loadZone = saved }()
	day, source := resolveToday(nil, "UTC", now)
	equal(t, "2026-10-20", day)
	equal(t, "the default time zone UTC", source)
}

func TestTheReleaseRangeHasOneEndOnly(t *testing.T) {
	released, scheduled := releaseRange(today, true), releaseRange(today, false)
	equal(t, today, released["end_date"])
	isTrue(t, released["start_date"] == nil, "no start date up to today")
	equal(t, today, scheduled["start_date"])
	isTrue(t, scheduled["end_date"] == nil, "no end date from today")
}
