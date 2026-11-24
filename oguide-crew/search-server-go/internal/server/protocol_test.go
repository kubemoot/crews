package server

import (
	"bytes"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestInitializeAnswersWithTheClientsProtocolVersion(t *testing.T) {
	out := rpc(t, newServer(answers(), Config{}),
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}`)
	result := out["result"].(m)
	equal(t, "2025-06-18", result["protocolVersion"])
	isTrue(t, result["capabilities"].(m)["tools"] != nil, "tools capability")
	equal(t, "oguide-search", result["serverInfo"].(m)["name"])
}

func TestInitializeWithoutAVersionUsesTheServers(t *testing.T) {
	out := rpc(t, newServer(answers(), Config{}), `{"jsonrpc":"2.0","id":1,"method":"initialize"}`)
	equal(t, "2025-03-26", out["result"].(m)["protocolVersion"])
}

func TestANotificationGetsNoReply(t *testing.T) {
	isTrue(t, rpc(t, newServer(answers(), Config{}), `{"jsonrpc":"2.0","method":"notifications/initialized"}`) == nil,
		"no reply")
}

func TestToolsListNamesTheFiveToolsWithOneArgumentEach(t *testing.T) {
	out := rpc(t, newServer(answers(), Config{}), `{"jsonrpc":"2.0","id":2,"method":"tools/list"}`)
	tools := out["result"].(m)["tools"].([]any)
	names := make([]string, 0, len(tools))
	for _, tool := range tools {
		fields := tool.(m)
		names = append(names, fields["name"].(string))
		equal(t, 1, len(fields["inputSchema"].(m)["properties"].(m)), fields["name"].(string))
		equal(t, "object", fields["inputSchema"].(m)["type"])
	}
	equal(t, []string{"find_released", "find_scheduled", "find_by_author", "find_title", "find_live_events"}, names)
}

func TestAnUnknownToolIsAProtocolError(t *testing.T) {
	out := rpc(t, newServer(answers(), Config{}),
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search"}}`)
	equal(t, float64(-32602), out["error"].(m)["code"])
}

func TestAnUnknownMethodIsAProtocolError(t *testing.T) {
	out := rpc(t, newServer(answers(), Config{}), `{"jsonrpc":"2.0","id":4,"method":"nope"}`)
	equal(t, float64(-32601), out["error"].(m)["code"])
}

func TestServeAnswersLineByLineAndSurvivesGarbage(t *testing.T) {
	var out bytes.Buffer
	in := strings.NewReader("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\nnot json\n\n")
	if err := newServer(answers(), Config{}).Serve(in, &out); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	equal(t, 2, len(lines))
	equal(t, m{}, decoded(t, mustParse(t, lines[0]))["result"])
	equal(t, float64(-32700), decoded(t, mustParse(t, lines[1]))["error"].(m)["code"])
}

func TestServeAnswersAFinalLineWithoutANewline(t *testing.T) {
	var out bytes.Buffer
	if err := newServer(answers(), Config{}).Serve(strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}`), &out); err != nil {
		t.Fatal(err)
	}
	contains(t, out.String(), `"result":{}`)
}

func TestTextAfterAMessageIsAParseError(t *testing.T) {
	var out bytes.Buffer
	_ = newServer(answers(), Config{}).Serve(strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"} x`+"\n"), &out)
	contains(t, out.String(), "-32700")
}

func TestAMessageThatIsNotAnObjectGetsAnErrorReply(t *testing.T) {
	for _, text := range []string{`[]`, `5`, `"x"`} {
		out := rpc(t, newServer(answers(), Config{}), text)
		equal(t, float64(-32600), out["error"].(m)["code"], text)
	}
}

func TestParamsThatAreNotAnObjectAreIgnored(t *testing.T) {
	out := rpc(t, newServer(answers(), Config{}), `{"jsonrpc":"2.0","id":1,"method":"tools/list","params":[1]}`)
	equal(t, 5, len(out["result"].(m)["tools"].([]any)))
}

func TestAReplyEchoesANumericOrTextId(t *testing.T) {
	s := newServer(answers(), Config{})
	equal(t, float64(7), rpc(t, s, `{"jsonrpc":"2.0","id":7,"method":"ping"}`)["id"])
	equal(t, "abc", rpc(t, s, `{"jsonrpc":"2.0","id":"abc","method":"ping"}`)["id"])
}

func TestArgumentsThatAreNotAnObjectAreRefused(t *testing.T) {
	payload, failed := callTextRaw(t, newServer(answers(), Config{}), toolCall("find_released", `["x"]`, ""))
	isTrue(t, failed, "an error result")
	contains(t, payload, "needs its one text argument")
}

// callTextRaw is the text of a tools/call result that is not JSON, with whether it was an error.
func callTextRaw(t *testing.T, s *Server, text string) (string, bool) {
	t.Helper()
	result := rpc(t, s, text)["result"].(m)
	return result["content"].([]any)[0].(m)["text"].(string), result["isError"].(bool)
}

func TestAMissingArgumentIsAnErrorTheModelCanRead(t *testing.T) {
	text, failed := callTextRaw(t, newServer(answers(), Config{}), toolCall("find_released", `{}`, ""))
	isTrue(t, failed, "an error")
	contains(t, text, "needs its one text argument")
}

func TestAnArgumentThatIsNotTextIsRefused(t *testing.T) {
	_, failed := callTextRaw(t, newServer(answers(), Config{}), toolCall("find_by_author", `{"name":["a"]}`, ""))
	isTrue(t, failed, "an error")
}

func TestAVeryLongArgumentIsRefused(t *testing.T) {
	long := strings.Repeat("x", maxArgumentChars+1)
	_, failed := callTextRaw(t, newServer(answers(), Config{}), toolCall("find_released", `{"topic":"`+long+`"}`, ""))
	isTrue(t, failed, "an error")
	_, failed = callTextRaw(t, newServer(answers(), Config{}),
		toolCall("find_released", `{"topic":"`+strings.Repeat("x", maxArgumentChars)+`"}`, ""))
	isTrue(t, !failed, "300 characters is allowed")
}

func TestALongArgumentCountsCharactersNotBytes(t *testing.T) {
	long := strings.Repeat("\u00e9", maxArgumentChars)
	_, failed := callTextRaw(t, newServer(answers(), Config{}), toolCall("find_released", `{"topic":"`+long+`"}`, ""))
	isTrue(t, !failed, "300 two-byte characters are allowed")
}

func TestAnUnreachableCatalogIsAClearFailure(t *testing.T) {
	catalog := failing(catalogErr("the catalog is unreachable (URLError)"))
	text, failed := callTextRaw(t, newServer(catalog, Config{}), toolCall("find_released", `{"topic":"x"}`, ""))
	isTrue(t, failed, "an error")
	equal(t, "The O'Reilly catalog could not be searched: the catalog is unreachable (URLError)", text)
}

func TestAnEmptyResultIsNotAnError(t *testing.T) {
	payload, failed := callText(t, rpc(t, newServer(answers(nil), Config{}), toolCall("find_released", `{"topic":"zzz"}`, "")))
	isTrue(t, !failed, "not an error")
	equal(t, []any{}, payload["released"])
}

func TestAnItemWithOddFieldTypesIsAnErrorNotACrash(t *testing.T) {
	catalog := answers([]m{{"publication_date": jsonNumber("20260101")}})
	text, failed := callTextRaw(t, newServer(catalog, Config{}), toolCall("find_released", `{"topic":"x"}`, ""))
	isTrue(t, failed, "an error")
	contains(t, text, "shape this server does not know")
}

func TestAnEmptySearchSaysNothingWasFoundAndIsNotAnError(t *testing.T) {
	payload, failed := callText(t, rpc(t, newServer(answers(nil), Config{}), toolCall("find_released", `{"topic":"zzz"}`, "")))
	isTrue(t, !failed, "not an error")
	equal(t, "Nothing found for 'zzz' in the O'Reilly catalog as of 2026-10-20.", payload["message"])
}

func TestASearchWithResultsHasNoMessage(t *testing.T) {
	payload, _ := callText(t, rpc(t, newServer(answers([]m{book("B", "2026-01-01")}), Config{}),
		toolCall("find_released", `{"topic":"x"}`, "")))
	isTrue(t, payload["message"] == nil, "no message")
}

func TestAnAuthorSearchWithOnlyOtherPeoplesItemsSaysNothingWasFound(t *testing.T) {
	catalog := answers([]m{book("B", "2026-01-01", m{"authors": list("Someone Else")})}, nil)
	payload, _ := callText(t, rpc(t, newServer(catalog, Config{}), toolCall("find_by_author", `{"name":"Neal Ford"}`, "")))
	contains(t, payload["message"].(string), "Nothing found")
}

func TestAnEmptyTitleOrEventsSearchSaysNothingWasFound(t *testing.T) {
	for tool, key := range map[string]string{"find_title": "title", "find_live_events": "topic"} {
		payload, failed := callText(t, rpc(t, newServer(answers(nil), Config{}), toolCall(tool, `{"`+key+`":"zzz"}`, "")))
		contains(t, payload["message"].(string), "Nothing found")
		isTrue(t, !failed, tool)
	}
}

func TestThePointerIsNotAnError(t *testing.T) {
	payload, failed := callText(t, rpc(t, newServer(answers(booksByFord("2025-01-01", 3)), Config{}),
		toolCall("find_released", `{"topic":"Neal Ford"}`, "")))
	isTrue(t, !failed, "not an error")
	contains(t, payload["message"].(string), "find_by_author")
}

// clock is a clock a test moves by hand.
type clock struct{ at time.Time }

func (c *clock) now() time.Time { return c.at }

func (c *clock) advance(seconds int) { c.at = c.at.Add(time.Duration(seconds) * time.Second) }

func repeating() (*Server, *fakeCatalog, *clock) {
	tick := &clock{at: now}
	catalog := answers([]m{book("B", "2026-01-01")}, []m{book("B", "2026-01-01")})
	return newServer(catalog, Config{Now: tick.now}), catalog, tick
}

func TestTheSameSearchWithinTheWindowGetsTheSameResultsWithANote(t *testing.T) {
	s, catalog, tick := repeating()
	first, _ := callText(t, rpc(t, s, toolCall("find_released", `{"topic":"Vector  DBs"}`, "")))
	tick.advance(10)
	again, _ := callText(t, rpc(t, s, toolCall("find_released", `{"topic":"vector dbs"}`, "")))
	isTrue(t, first["released"] != nil, "first has results")
	equal(t, repeatNote, again["repeat"])
	equal(t, first["released"], again["released"])
	isTrue(t, first["repeat"] == nil, "the first has no repeat note")
	equal(t, 1, len(catalog.calls))
}

func TestTheSameSearchAfterTheWindowRunsAgain(t *testing.T) {
	s, catalog, tick := repeating()
	rpc(t, s, toolCall("find_released", `{"topic":"x"}`, ""))
	tick.advance(21)
	rpc(t, s, toolCall("find_released", `{"topic":"x"}`, ""))
	equal(t, 2, len(catalog.calls))
}

func TestARepeatOfNothingFoundIsAlsoAnsweredFromMemory(t *testing.T) {
	s := newServer(answers(nil, nil), Config{})
	rpc(t, s, toolCall("find_released", `{"topic":"zzz"}`, ""))
	again, _ := callText(t, rpc(t, s, toolCall("find_released", `{"topic":"zzz"}`, "")))
	equal(t, repeatNote, again["repeat"])
	contains(t, again["message"].(string), "Nothing found")
}

func TestASecondCallerOfTheSameSearchGetsTheDataNotJustANote(t *testing.T) {
	s := newServer(answers(nil, nil, nil, nil, nil, nil), Config{})
	rpc(t, s, toolCall("find_by_author", `{"name":"Bruce Hopkins"}`, ""))
	again, _ := callText(t, rpc(t, s, toolCall("find_by_author", `{"name":"Bruce Hopkins"}`, "")))
	isTrue(t, again["released_books"] != nil, "released_books")
	isTrue(t, again["upcoming_live_events"] != nil, "upcoming_live_events")
}

func TestAFailedSearchIsNotRemembered(t *testing.T) {
	s := newServer(failing(catalogErr("x")), Config{})
	_, failed := callTextRaw(t, s, toolCall("find_released", `{"topic":"x"}`, ""))
	isTrue(t, failed, "failed")
	s2 := newServer(answers([]m{book("B", "2026-01-01")}), Config{})
	ok, _ := callText(t, rpc(t, s2, toolCall("find_released", `{"topic":"x"}`, "")))
	isTrue(t, ok["repeat"] == nil, "no repeat")
}

func TestAFailedSearchIsNotRememberedSoARetryStillFails(t *testing.T) {
	catalog := failing(catalogErr("down"))
	s := newServer(catalog, Config{})
	for i := 0; i < 2; i++ {
		_, failed := callTextRaw(t, s, toolCall("find_released", `{"topic":"x"}`, ""))
		isTrue(t, failed, "failed")
	}
	equal(t, 2, len(catalog.calls))
}

func TestADifferentArgumentOrToolIsNotARepeat(t *testing.T) {
	catalog := answers(nil, nil, nil)
	s := newServer(catalog, Config{})
	rpc(t, s, toolCall("find_released", `{"topic":"x"}`, ""))
	rpc(t, s, toolCall("find_released", `{"topic":"y"}`, ""))
	rpc(t, s, toolCall("find_scheduled", `{"topic":"x"}`, ""))
	equal(t, 3, len(catalog.calls))
}

func TestTwoThreadsAskingTheSameThingBothGetResults(t *testing.T) {
	catalog := answers([]m{book("B", "2026-01-01")}, []m{book("B", "2026-01-01")})
	s := newServer(catalog, Config{})
	for _, thread := range []string{"t1", "t2"} {
		rpc(t, s, toolCall("find_released", `{"topic":"x"}`, `{"threadId":"`+thread+`"}`))
	}
	equal(t, 2, len(catalog.calls))
}

func TestTheThreadAndTheRepeatGuardPassThroughHandle(t *testing.T) {
	s := newServer(answers([]m{book("B", "2026-01-01")}, []m{book("B", "2026-01-01")}), Config{})
	ask := func(thread string) m {
		payload, _ := callText(t, rpc(t, s, toolCall("find_released", `{"topic":"x"}`, `{"threadId":"`+thread+`"}`)))
		return payload
	}
	first := ask("t1")
	isTrue(t, first["released"] != nil, "first")
	again := ask("t1")
	equal(t, repeatNote, again["repeat"])
	equal(t, first["released"], again["released"])
	isTrue(t, ask("t2")["released"] != nil, "another thread")
}

func TestAnotherPersonInTheSameThreadIsNotAnsweredFromTheFirstPersonsSearch(t *testing.T) {
	catalog := answers([]m{book("B", "2026-01-01")}, []m{book("B", "2026-01-01")})
	s := newServer(catalog, Config{})
	for _, person := range []string{"p-1", "p-2"} {
		rpc(t, s, toolCall("find_released", `{"topic":"x"}`, `{"conversationId":"c","principalId":"`+person+`"}`))
	}
	equal(t, 2, len(catalog.calls))
}

func TestServeKeepsOneGuardAcrossMessages(t *testing.T) {
	s := newServer(answers([]m{book("B", "2026-01-01")}, []m{book("B", "2026-01-01")}), Config{})
	call := `{"jsonrpc":"2.0","id":%d,"method":"tools/call","params":{"name":"find_released","arguments":{"topic":"x"}}}` + "\n"
	var out bytes.Buffer
	_ = s.Serve(strings.NewReader(strings.Replace(call, "%d", "1", 1)+strings.Replace(call, "%d", "2", 1)), &out)
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	first, _ := callText(t, decoded(t, mustParse(t, lines[0])))
	second, _ := callText(t, decoded(t, mustParse(t, lines[1])))
	isTrue(t, first["released"] != nil, "first")
	equal(t, first["released"], second["released"])
	equal(t, repeatNote, second["repeat"])
}

func TestTheRepeatStoreIsBoundedAndDropsTheOldest(t *testing.T) {
	tick := &clock{at: now}
	recent := NewRecent(tick.now, 20*time.Second, 3)
	for n := 0; n < 5; n++ {
		tick.advance(1)
		recent.remember("q"+string(rune('0'+n)), newObj().set("n", n))
	}
	equal(t, 3, recent.size())
	isTrue(t, recent.earlier("q0") == nil, "q0 is gone")
	isTrue(t, recent.earlier("q1") == nil, "q1 is gone")
	equal(t, 4, recent.earlier("q4").get("n"))
}

func TestRememberingPrunesExpiredSearchesAndRefreshesARepeatedKey(t *testing.T) {
	tick := &clock{at: now}
	recent := NewRecent(tick.now, 20*time.Second, 3)
	recent.remember("x", newObj().set("n", 1))
	tick.advance(29)
	recent.remember("y", newObj().set("n", 2))
	equal(t, 1, recent.size())
	recent.remember("y", newObj().set("n", 3))
	equal(t, 1, recent.size())
	equal(t, 3, recent.earlier("y").get("n"))
}

type panickingCatalog struct{ fakeCatalog }

func (panickingCatalog) Search(map[string]any) ([]map[string]any, error) {
	return nil, errors.New("secret detail sekret-key-value-123")
}

func TestAnyFailureInOneMessageLeavesTheServerRunning(t *testing.T) {
	in := `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"find_released","arguments":{"topic":"x"}}}` +
		"\n" + `{"jsonrpc":"2.0","id":2,"method":"ping"}` + "\n"
	var out bytes.Buffer
	_ = newServer(&panickingCatalog{}, Config{}).Serve(strings.NewReader(in), &out)
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	equal(t, float64(-32603), decoded(t, mustParse(t, lines[0]))["error"].(m)["code"])
	equal(t, m{}, decoded(t, mustParse(t, lines[1]))["result"])
	isTrue(t, !strings.Contains(out.String(), "sekret-key-value-123"), "no detail leaks")
}

type crashingCatalog struct{ fakeCatalog }

func (crashingCatalog) Search(map[string]any) ([]map[string]any, error) { panic("boom") }

func TestAPanicInOneMessageIsAnInternalErrorAndTheServerRuns(t *testing.T) {
	in := `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"find_released","arguments":{"topic":"x"}}}` +
		"\n" + `{"jsonrpc":"2.0","id":2,"method":"ping"}` + "\n"
	var out bytes.Buffer
	_ = newServer(&crashingCatalog{}, Config{}).Serve(strings.NewReader(in), &out)
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	equal(t, 2, len(lines))
	equal(t, float64(-32603), decoded(t, mustParse(t, lines[0]))["error"].(m)["code"])
}

func TestACatalogCallTimesOutWithinFifteenSeconds(t *testing.T) {
	isTrue(t, timeout <= 15*time.Second, "the timeout is at most fifteen seconds")
}
