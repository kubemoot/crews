package server

import (
	"errors"
	"strings"
	"testing"
)

// run calls a handler and returns its payload as plain values.
func run(t *testing.T, h handler, c Catalog, value string) m {
	t.Helper()
	out, err := h(c, value, today)
	if err != nil {
		t.Fatalf("handler: %v", err)
	}
	return decoded(t, out)
}

func message(out m) string {
	text, _ := out["message"].(string)
	return text
}

func TestFindReleasedFiltersToDatesUpToToday(t *testing.T) {
	catalog := answers([]m{book("A", "2026-01-01")})
	out := run(t, findReleased, catalog, "vector databases")
	call := catalog.calls[0]
	equal(t, "vector databases", call["query"])
	equal(t, itemsPerSearch, call["n_items"])
	isTrue(t, call["content_types"] == nil, "no content types")
	rng := call["date_range"].(map[string]any)
	equal(t, today, rng["end_date"])
	isTrue(t, rng["start_date"] == nil, "no start date")
	equal(t, []string{"A"}, titles(t, out["released"]))
}

func TestFindScheduledFiltersToDatesFromToday(t *testing.T) {
	catalog := answers([]m{book("B", "2027-01-01")})
	out := run(t, findScheduled, catalog, "agents")
	rng := catalog.calls[0]["date_range"].(map[string]any)
	equal(t, today, rng["start_date"])
	isTrue(t, rng["end_date"] == nil, "no end date")
	equal(t, "Scheduled", out["scheduled"].([]any)[0].(m)["status"])
}

func TestScheduledRecordedContentLeavesLiveEventsOut(t *testing.T) {
	out := run(t, findScheduled, answers([]m{book("B", "2027-01-01"), event("Live", []string{"2026-12-01"})}), "agents")
	equal(t, []string{"B"}, titles(t, out["scheduled"]))
}

func TestTheAuthorSearchMakesFiveCalls(t *testing.T) {
	ford := list("Neal Ford")
	catalog := answers([]m{book("Past", "2025-01-01", m{"authors": ford})},
		[]m{book("Future", "2027-02-25", m{"authors": ford})})
	out := run(t, findByAuthor, catalog, "Neal Ford")
	equal(t, 5, len(catalog.calls))
	past, future, otherPast, otherFuture := catalog.calls[0], catalog.calls[1], catalog.calls[2], catalog.calls[3]
	equal(t, []string{"Neal Ford"}, past["author_filter"])
	equal(t, "*", past["query"])
	equal(t, today, past["date_range"].(map[string]any)["end_date"])
	equal(t, "desc", past["sort_order"])
	equal(t, today, future["date_range"].(map[string]any)["start_date"])
	equal(t, "asc", future["sort_order"])
	equal(t, []string{"Past"}, titles(t, out["released_books"]))
	equal(t, []string{"Future"}, titles(t, out["scheduled_books"]))
	equal(t, "desc", otherPast["sort_order"])
	equal(t, "asc", otherFuture["sort_order"])
}

func TestAnItemInBothAuthorCallsAppearsOnce(t *testing.T) {
	shared := by(event("Both", []string{"2026-12-01"}), "Nina Nguyen")
	out := run(t, findByAuthor, answers(nil, nil, []m{shared}, []m{shared}), "Nina Nguyen")
	equal(t, 1, len(out["released_other_formats"].([]any))+len(out["scheduled_other_formats"].([]any)))
}

func TestLiveEventsUseTheLiveEventTypeAndNoDateFilter(t *testing.T) {
	catalog := answers([]m{event("E", []string{"2026-11-01"})})
	out := run(t, findLiveEvents, catalog, "agentic AI")
	call := catalog.calls[0]
	equal(t, []string{"live-events"}, call["content_types"])
	equal(t, "upcoming_events", call["order_by"])
	isTrue(t, call["date_range"] == nil, "no date range")
	equal(t, "Scheduled", out["scheduled"].([]any)[0].(m)["status"])
}

func TestAnAuthorSearchListsTheirLiveEventsWithNoDateFilter(t *testing.T) {
	live := merge(event("Series", []string{"2026-11-19T16:00:00Z", "2026-12-03T16:00:00Z"}),
		m{"authors": list("Bruce Hopkins"), "publication_date": "2026-09-03"})
	catalog := answers(nil, nil, nil, nil, []m{live})
	out := run(t, findByAuthor, catalog, "Bruce Hopkins")
	equal(t, []string{"Series"}, titles(t, out["upcoming_live_events"]))
	equal(t, []any{"2026-11-19T16:00:00Z", "2026-12-03T16:00:00Z"},
		out["upcoming_live_events"].([]any)[0].(m)["live_event_start_dates"])
	call := catalog.calls[4]
	equal(t, []string{"live-events"}, call["content_types"])
	equal(t, []string{"Bruce Hopkins"}, call["author_filter"])
	equal(t, "upcoming_events", call["order_by"])
	isTrue(t, call["date_range"] == nil, "no date range")
	for _, other := range catalog.calls[:4] {
		for _, kind := range other["content_types"].([]string) {
			isTrue(t, kind != "live-events", "the four recorded searches leave live events out")
		}
	}
}

func TestAFailedLiveSearchIsNamedAndTheRestOfTheAuthorListStays(t *testing.T) {
	catalog := failingNth([]int{5}, []m{book("B", "2026-01-01", m{"authors": list("Bruce Hopkins")})})
	out := run(t, findByAuthor, catalog, "Bruce Hopkins")
	equal(t, 1, len(out["released_books"].([]any)))
	contains(t, message(out), "live events could not be searched")
}

func TestTheReleasedSearchLeavesLiveEventsToFindLiveEvents(t *testing.T) {
	out := run(t, findReleased, answers([]m{book("B", "2026-01-01"), event("E", []string{"2026-11-01"})}), "x")
	equal(t, []string{"B"}, titles(t, out["released"]))
}

func TestALiveEventTopicThatNamesAnAuthorPointsToFindByAuthor(t *testing.T) {
	events := make([]m, 0, 3)
	for _, name := range []string{"E0", "E1", "E2"} {
		events = append(events, by(event(name, []string{"2026-11-01"}), "Bruce Hopkins"))
	}
	contains(t, message(run(t, findLiveEvents, answers(events), "Bruce Hopkins")), "find_by_author")
}

func TestTheModelCannotSupplyDatesOrCounts(t *testing.T) {
	catalog := answers(nil)
	s := newServer(catalog, Config{})
	rpc(t, s, toolCall("find_released", `{"topic":"x","n_items":3,"date_range":{"end_date":"2000-01-01"}}`, ""))
	equal(t, itemsPerSearch, catalog.calls[0]["n_items"])
	equal(t, today, catalog.calls[0]["date_range"].(map[string]any)["end_date"])
}

func TestNamesMatchWithoutCaseInitialsAccentsOrOrder(t *testing.T) {
	wanted := nameTokens("Neal Ford")
	for _, author := range []string{"Neal Ford", "neal ford", "Neal E. Ford", "Ford, Neal", "NEAL  FORD Jr."} {
		isTrue(t, hasAuthor(mustItem(t, m{"authors": list("Neal Ford")}), wanted), author)
	}
	isTrue(t, hasAuthor(mustItem(t, m{"authors": list("Zoe M\u00fcller")}), nameTokens("Zoe Muller")), "accents")
}

func TestOtherPeopleDoNotMatch(t *testing.T) {
	wanted := nameTokens("Neal Ford")
	for _, authors := range []any{list("Neil Ford"), list("Neal Fordham"), list("Henry Ford"), list("Mark Richards"),
		list(), nil} {
		isTrue(t, !hasAuthor(mustItem(t, m{"authors": authors}), wanted), "other people")
	}
}

func TestFindByAuthorKeepsOnlyTheAuthorsItems(t *testing.T) {
	mine := book("Mine", "2025-01-01", m{"authors": list("Mark Richards", "Neal E. Ford")})
	other := book("Other", "2025-02-01", m{"authors": list("Luca Mezzalira")})
	out := run(t, findByAuthor, answers([]m{mine, other}, nil, []m{event("Soon", []string{"2026-12-01"})}), "Neal Ford")
	equal(t, []string{"Mine"}, titles(t, out["released_books"]))
	equal(t, []any{}, out["scheduled_books"])
	equal(t, []any{}, out["released_other_formats"])
}

func TestEveryBookIsReturnedThoughRecentEventsAndVideosAreMany(t *testing.T) {
	var events, books []m
	for i := 0; i < 30; i++ {
		events = append(events, merge(event("Live "+string(rune('A'+i)), []string{"2026-11-" + twoDigits(i+1)}),
			m{"authors": list("Sam Newman"), "publication_date": "2026-09-01"}))
	}
	for i := 0; i < 5; i++ {
		books = append(books, book("Book "+string(rune('A'+i)), "201"+string(rune('0'+i))+"-03-01",
			m{"authors": list("Sam Newman")}))
	}
	catalog := answers(books, nil, events[:25], nil)
	out := run(t, findByAuthor, catalog, "Sam Newman")
	equal(t, 5, len(out["released_books"].([]any)))
	equal(t, 25, len(out["scheduled_other_formats"].([]any)))
	equal(t, []string{"books"}, catalog.calls[0]["content_types"])
	equal(t, []string{"books"}, catalog.calls[1]["content_types"])
	for _, kind := range catalog.calls[2]["content_types"].([]string) {
		isTrue(t, kind != "books", "the other formats leave books out")
	}
	equal(t, itemsPerBooks, catalog.calls[0]["n_items"])
	equal(t, itemsPerSearch, catalog.calls[2]["n_items"])
}

func twoDigits(n int) string {
	if n < 10 {
		return "0" + string(rune('0'+n))
	}
	return string(rune('0'+n/10)) + string(rune('0'+n%10))
}

func TestAFailedSearchLosesOnlyItsGroup(t *testing.T) {
	mine := []m{book("Old", "2020-01-01", m{"authors": list("Sam Newman")})}
	out := run(t, findByAuthor, failingNth([]int{2}, mine), "Sam Newman")
	equal(t, []string{"Old"}, titles(t, out["released_books"]))
	contains(t, message(out), "scheduled books could not be searched")
}

func TestTheToolFailsOnlyWhenEverySearchFails(t *testing.T) {
	_, err := findByAuthor(failing(catalogErr("down")), "Sam Newman", today)
	var found *CatalogError
	isTrue(t, errors.As(err, &found), "a catalog error")
	equal(t, "every author search failed", found.Msg)
}

func TestAGroupAtItsLimitSaysItMayBeIncomplete(t *testing.T) {
	var books []m
	for i := 0; i < itemsPerBooks; i++ {
		books = append(books, book("B"+twoDigits(i), "2020-01-01", m{"authors": list("Sam Newman"),
			"url": "u" + twoDigits(i)}))
	}
	out := run(t, findByAuthor, answers(books, nil, nil, nil), "Sam Newman")
	equal(t, itemsPerBooks, len(out["released_books"].([]any)))
	contains(t, message(out), "released books reached the limit of 50")
}

func TestBelowTheLimitThereIsNoMessage(t *testing.T) {
	out := run(t, findByAuthor, answers([]m{book("B", "2020-01-01", m{"authors": list("Sam Newman")})}), "Sam Newman")
	isTrue(t, out["message"] == nil, "no message")
}

func TestBooksByOtherPeopleAreDroppedFromTheBookGroups(t *testing.T) {
	mine := book("Mine", "2020-01-01", m{"authors": list("Sam Newman")})
	theirs := book("Theirs", "2020-01-01", m{"authors": list("Sam Newmann")})
	out := run(t, findByAuthor, answers([]m{mine, theirs}, []m{theirs}), "Sam Newman")
	equal(t, []string{"Mine"}, titles(t, out["released_books"]))
	equal(t, []any{}, out["scheduled_books"])
}

func TestAnItemInBothGroupsIsListedOnceAmongTheBooks(t *testing.T) {
	both := book("Both", "2020-01-01", m{"authors": list("Sam Newman")})
	out := run(t, findByAuthor, answers([]m{both}, nil, []m{both}), "Sam Newman")
	equal(t, []string{"Both"}, titles(t, out["released_books"]))
	equal(t, []any{}, out["released_other_formats"])
}

func TestOneEmptyGroupIsNotNothingFound(t *testing.T) {
	found, _ := findByAuthor(answers([]m{book("B", "2020-01-01", m{"authors": list("Sam Newman")})}), "Sam Newman", today)
	isTrue(t, !withNothingFound(found, "Sam Newman", today).has("message"), "no nothing-found message")
}

func TestAnAuthorWithOnlyBooks(t *testing.T) {
	books := []m{book("One", "2019-01-01", m{"authors": list("Sam Newman")}),
		book("Two", "2021-01-01", m{"authors": list("Sam Newman")})}
	out := run(t, findByAuthor, answers(books), "Sam Newman")
	equal(t, []string{"Two", "One"}, titles(t, out["released_books"]))
	equal(t, []any{}, out["released_other_formats"])
	equal(t, []any{}, out["scheduled_other_formats"])
}

func TestAnAuthorWithNothingGetsThePlainMessage(t *testing.T) {
	found, _ := findByAuthor(answers(), "Sam Newman", today)
	equal(t, []any{}, decoded(t, found)["released_books"])
	contains(t, message(decoded(t, withNothingFound(found, "Sam Newman", today))), "Nothing found")
}

func TestScheduledBooksStayApartFromReleasedBooks(t *testing.T) {
	mine := []m{book("Old", "2020-01-01", m{"authors": list("Sam Newman")})}
	soon := []m{book("Next", "2027-02-01", m{"authors": list("Sam Newman")})}
	out := run(t, findByAuthor, answers(mine, soon), "Sam Newman")
	equal(t, []string{"Old"}, titles(t, out["released_books"]))
	equal(t, []string{"Next"}, titles(t, out["scheduled_books"]))
	equal(t, []any{}, out["scheduled_other_formats"])
}

func booksByFord(date string, count int) []m {
	var out []m
	for i := 0; i < count; i++ {
		out = append(out, book("B"+twoDigits(i), date, m{"authors": list("Neal Ford")}))
	}
	return out
}

func TestATopicThatNamesAnAuthorPointsToFindByAuthor(t *testing.T) {
	var items []m
	for i := 0; i < 3; i++ {
		items = append(items, book("B"+twoDigits(i), "2025-01-01", m{"authors": list("Neal Ford", "X Y")}))
	}
	out := run(t, findReleased, answers(items), "Neal Ford forthcoming")
	isTrue(t, out["released"] == nil, "no released list")
	contains(t, message(out), "find_by_author")
	contains(t, message(out), "Neal Ford")
}

func TestTheSamePointerServesFindScheduled(t *testing.T) {
	contains(t, message(run(t, findScheduled, answers(booksByFord("2027-01-01", 3)), "Neal Ford")),
		"find_by_author")
}

func TestATopicThatIsNotANameIsNotRedirected(t *testing.T) {
	out := run(t, findReleased, answers(booksByFord("2025-01-01", 3)), "software architecture")
	equal(t, 3, len(out["released"].([]any)))
}

func TestOneOrTwoItemsByANamesakeDoNotRedirect(t *testing.T) {
	out := run(t, findReleased, answers(booksByFord("2025-01-01", 2)), "Neal Ford")
	isTrue(t, out["released"] != nil, "released list")
}

func TestANameWithNoUsableWordsAsksForAFullNameAndSearchesNothing(t *testing.T) {
	for _, name := range []string{"J", "Jr", "A. B."} {
		catalog := answers([]m{book("B", "2025-01-01")}, nil)
		out := run(t, findByAuthor, catalog, name)
		contains(t, message(out), "full name")
		equal(t, 0, len(catalog.calls), name)
	}
}

func TestANameInAnotherScriptMatchesItselfOnly(t *testing.T) {
	wanted := nameTokens("\u674e\u660e")
	isTrue(t, hasAuthor(mustItem(t, m{"authors": list("\u674e\u660e")}), wanted), "itself")
	isTrue(t, !hasAuthor(mustItem(t, m{"authors": list("\u738b\u82b3")}), wanted), "another")
}

func TestANameWrittenSurnameFirstWorksThroughFindByAuthor(t *testing.T) {
	out := run(t, findByAuthor, answers([]m{book("Mine", "2025-01-01", m{"authors": list("Neal Ford")})}), "Ford, Neal")
	equal(t, []string{"Mine"}, titles(t, out["released_books"]))
}

func TestAPublisherOrALongerTopicIsNotTakenForAPerson(t *testing.T) {
	var publishers []m
	for i := 0; i < 3; i++ {
		publishers = append(publishers, book("B"+twoDigits(i), "2025-01-01",
			m{"authors": list("Google Cloud"), "publisher_names": list("Google Cloud")}))
	}
	isTrue(t, run(t, findReleased, answers(publishers), "Google Cloud")["released"] != nil, "a publisher")
	out := run(t, findReleased, answers(booksByFord("2025-01-01", 3)),
		"Neal Ford and the history of software architecture")
	isTrue(t, out["released"] != nil, "a longer topic")
}

func TestLiveEventsByAPersonDoNotTriggerTheScheduledPointer(t *testing.T) {
	var events []m
	for i := 0; i < 3; i++ {
		events = append(events, by(event("E"+twoDigits(i), []string{"2026-12-01"}), "Neal Ford"))
	}
	text, _ := encodeJSON(runObj(t, findScheduled, answers(events), "Neal Ford"))
	isTrue(t, !strings.Contains(text, "find_by_author"), "no pointer")
}

func runObj(t *testing.T, h handler, c Catalog, value string) *obj {
	t.Helper()
	out, err := h(c, value, today)
	if err != nil {
		t.Fatalf("handler: %v", err)
	}
	return out
}

func TestFindTitleHasNoDateFilterAndTenItems(t *testing.T) {
	catalog := answers(nil)
	run(t, findTitle, catalog, "Architecture as Code")
	equal(t, m{"query": "Architecture as Code", "n_items": itemsPerTitle}, catalog.calls[0])
}

func TestFindTitleReturnsReleasedAndScheduledBestMatchFirst(t *testing.T) {
	relevance := func(value string) m { return m{"relevance_score": jsonNumber(value)} }
	catalog := answers([]m{book("Weak", "2019-01-01", relevance("0.2")), book("Future", "2027-02-25", relevance("0.9")),
		book("Mid", "2020-01-01", relevance("0.5"))})
	out := run(t, findTitle, catalog, "x")["items"].([]any)
	equal(t, []string{"Future", "Mid", "Weak"}, titles(t, out))
	equal(t, "Scheduled", out[0].(m)["status"])
	equal(t, "Released", out[1].(m)["status"])
}

// The catalog's date for a same-named author entry is in these cases; each is one entry.
func taxBook(i int) m {
	return book("Tax Law "+twoDigits(i), "2020-05-01", m{"authors": list("Bruce R. Hopkins"),
		"tags": list("Nonprofit law", "Tax"), "publisher_names": list("Wiley")})
}

func sameNameCatalog() *fakeCatalog {
	aiBook := book("AI Agents", "2026-03-01", m{"authors": list("Bruce Hopkins"), "tags": list("AI", "Agents")})
	course := merge(event("Agents Live", []string{"2026-11-19T16:00:00Z"}), m{"authors": list("Bruce Hopkins"),
		"tags": list("AI")})
	first := []m{aiBook}
	for i := 0; i < 15; i++ {
		first = append(first, taxBook(i))
	}
	return answers(first, nil, nil, nil, []m{course})
}

func TestTwoEntriesForOneNameAreReturnedAsSeparateGroups(t *testing.T) {
	out := run(t, findByAuthor, sameNameCatalog(), "Bruce Hopkins")
	groups := out["authors"].([]any)
	equal(t, []string{"Bruce Hopkins", "Bruce R. Hopkins"}, []string{groups[0].(m)["author"].(string),
		groups[1].(m)["author"].(string)})
	ai, tax := groups[0].(m), groups[1].(m)
	equal(t, []string{"AI Agents"}, titles(t, ai["released_books"]))
	equal(t, []string{"Agents Live"}, titles(t, ai["upcoming_live_events"]))
	equal(t, 15, len(tax["released_books"].([]any)))
	equal(t, 15, int(tax["item_counts"].(m)["released_books"].(float64)))
	equal(t, []any{"Nonprofit law", "Tax", "Tax Law 00", "Tax Law 01", "Tax Law 02"}, tax["topics"])
	equal(t, []any{"Wiley"}, tax["publishers"])
	equal(t, []any{"AI", "Agents", "AI Agents", "Agents Live"}, ai["topics"])
	isTrue(t, out["released_books"] == nil, "no flat list beside the groups")
}

func TestTheResultSaysTheNameMatchesMoreThanOneAuthor(t *testing.T) {
	out := run(t, findByAuthor, sameNameCatalog(), "Bruce Hopkins")
	contains(t, message(out), "2 different author entries")
	contains(t, message(out), `"Bruce R. Hopkins"`)
}

func TestAMissingListNoteStaysBesideTheSameNameMessage(t *testing.T) {
	catalog := failingNth([]int{5}, []m{taxBook(1), book("B", "2020-01-01", m{"authors": list("Bruce Hopkins")})})
	out := run(t, findByAuthor, catalog, "Bruce Hopkins")
	contains(t, message(out), "different author entries")
	contains(t, message(out), "live events could not be searched")
}

func TestTopicsUseTagsThenTitlesAndSkipWhatIsNotText(t *testing.T) {
	all := items(t, m{"title": "A", "tags": []any{}}, m{"title": "B", "tags": []any{"x", jsonNumber("5"), nil, []any{"y"}}},
		m{"title": "C"})
	equal(t, []any{"x", "A", "B", "C"}, topicsOf(all, defaultListLimit))
	equal(t, []any{"A", "B"}, topicsOf(items(t, m{"title": "A"}, m{"title": "B"}), defaultListLimit))
}

func TestARecordedItemGivesItsTagFormatAndPublisher(t *testing.T) {
	recordedVideo := m{"url": "https://learning.oreilly.com/videos/-/9780135480892/?orm_source=mcp",
		"page_count": nil, "title": "Building Intelligent AI Agents", "publication_date": "2025-09-19",
		"live_event_start_dates": nil, "marketing_type": "on-demand course", "publisher_names": list("Pearson"),
		"authors": list("Bruce Hopkins"), "tags": list("structured-learning"), "duration": jsonNumber("9089"),
		"display_format": "video", "relevance_score": jsonNumber("6.167e-05")}
	other := merge(recordedVideo, m{"authors": list("Bruce R. Hopkins"), "url": "u2", "tags": []any{}})
	out := run(t, findByAuthor, answers(nil, nil, []m{recordedVideo, other}, nil), "Bruce Hopkins")
	ai := out["authors"].([]any)[0].(m)
	equal(t, "Bruce Hopkins", ai["author"])
	equal(t, []any{"structured-learning", "Building Intelligent AI Agents"}, ai["topics"])
	equal(t, []any{"on-demand course"}, ai["formats"])
	equal(t, []any{"Pearson"}, ai["publishers"])
	equal(t, "2 h 31 min", ai["released_other_formats"].([]any)[0].(m)["duration"])
}

func TestAnItemListingTwoMatchingStringsIsInBothGroups(t *testing.T) {
	both := book("Joint", "2021-01-01", m{"authors": list("Bruce Hopkins", "Bruce R. Hopkins")})
	out := run(t, findByAuthor, answers([]m{both}), "Bruce Hopkins")
	groups := out["authors"].([]any)
	equal(t, []float64{1, 1}, []float64{groups[0].(m)["item_counts"].(m)["released_books"].(float64),
		groups[1].(m)["item_counts"].(m)["released_books"].(float64)})
}

func TestOneEntryKeepsTheFlatResultWithNoGroups(t *testing.T) {
	out := run(t, findByAuthor, answers([]m{taxBook(1)}), "Bruce Hopkins")
	isTrue(t, out["authors"] == nil, "no groups")
	isTrue(t, out["message"] == nil, "no message")
	equal(t, 1, len(out["released_books"].([]any)))
}
