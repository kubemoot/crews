package server

import (
	"strings"
	"testing"
)

const personMeta = `{"conversationId":"conv-1","principalId":"p-abc","timeZone":"UTC"}`

// relaying is a gateway that records the _meta each call carried.
func relaying(t *testing.T, relay bool) (*stubGateway, *GatewayCatalog) {
	t.Helper()
	g := newStubGateway(t)
	g.reply = m{"isError": false, "content": `{"search_results": []}`}
	return g, NewGatewayCatalog(g.srv.URL, relay)
}

func relayed(g *stubGateway) m {
	meta, _ := g.body["_meta"].(m)
	return meta
}

func TestASearchRelaysConversationAndPrincipalToTheGateway(t *testing.T) {
	g, catalog := relaying(t, true)
	rpc(t, newServer(catalog, Config{Expert: true}), toolCall("find_title", `{"title":"x"}`, personMeta))
	equal(t, m{"conversationId": "conv-1", "principalId": "p-abc"}, relayed(g))
}

func TestAnExpertCallRelaysThemToo(t *testing.T) {
	g, catalog := relaying(t, true)
	g.reply = m{"isError": false, "content": "{}"}
	rpc(t, newServer(catalog, Config{Expert: true}), toolCall("ask_experts", `{"question":"q"}`, personMeta))
	equal(t, m{"conversationId": "conv-1", "principalId": "p-abc"}, relayed(g))
}

func TestNothingIsRelayedUnlessPerPersonIsOn(t *testing.T) {
	g, catalog := relaying(t, false)
	rpc(t, newServer(catalog, Config{}), toolCall("find_title", `{"title":"x"}`, personMeta))
	isTrue(t, g.body["_meta"] == nil, "no _meta")
}

func TestOnlyTheTwoKeysAreRelayedAndOnlyAsShortText(t *testing.T) {
	g, catalog := relaying(t, true)
	meta := `{"conversationId":"` + strings.Repeat("c", 300) + `","principalId":"p-1","authorization":"Bearer X","timeZone":"UTC"}`
	rpc(t, newServer(catalog, Config{}), toolCall("find_title", `{"title":"x"}`, meta))
	equal(t, m{"principalId": "p-1"}, relayed(g))
	for _, bad := range []any{m{"principalId": 5}, m{"principalId": ""}, m{"principalId": []any{"a"}}, nil, "text"} {
		scoped := catalog.Scoped(bad).(*GatewayCatalog)
		equal(t, 0, len(scoped.context), "a bad meta relays nothing")
	}
}

func TestAModelArgumentCannotSetTheRelayedContext(t *testing.T) {
	g, catalog := relaying(t, true)
	rpc(t, newServer(catalog, Config{}), toolCall("find_title", `{"title":"x","principalId":"someone-else"}`,
		`{"timeZone":"UTC"}`))
	isTrue(t, g.body["_meta"] == nil, "no _meta")
	text, _ := encodeJSON(g.body)
	isTrue(t, !strings.Contains(text, "someone-else"), "the model's value is not relayed")
}

func TestACallDoesNotKeepThePreviousAskersContext(t *testing.T) {
	g, catalog := relaying(t, true)
	s := newServer(catalog, Config{})
	rpc(t, s, toolCall("find_title", `{"title":"one"}`, personMeta))
	rpc(t, s, toolCall("find_title", `{"title":"two"}`, `{"conversationId":"conv-2","principalId":"p-2"}`))
	equal(t, m{"conversationId": "conv-2", "principalId": "p-2"}, relayed(g))
	rpc(t, s, toolCall("find_title", `{"title":"three"}`, `{"timeZone":"UTC"}`))
	isTrue(t, g.body["_meta"] == nil, "no context from the call before")
}

func TestAFakeCatalogWithoutRelayStillWorks(t *testing.T) {
	payload, failed := callText(t, rpc(t, newServer(answers([]m{book("B", "2026-01-01")}), Config{}),
		toolCall("find_title", `{"title":"B"}`, personMeta)))
	isTrue(t, !failed, "not an error")
	equal(t, 1, len(payload["items"].([]any)))
}

func TestEveryDescriptionGetsTheAccessSentence(t *testing.T) {
	note := "Results reflect the asking person's own O'Reilly access."
	out := rpc(t, newServer(answers(), Config{Expert: true, Note: note}), `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	tools := out["result"].(m)["tools"].([]any)
	equal(t, 7, len(tools))
	for _, tool := range tools {
		equal(t, 1, strings.Count(tool.(m)["description"].(string), note), tool.(m)["name"].(string))
	}
}

func TestNoNoteLeavesTheDescriptionsUnchanged(t *testing.T) {
	out := rpc(t, newServer(answers(), Config{Expert: true}), `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	want := append(toolListing(""), expertListing("")...)
	equal(t, decoded(t, m{"tools": want})["tools"], out["result"].(m)["tools"])
}

func TestANoteAlreadyInADescriptionIsNotAppendedTwice(t *testing.T) {
	once := withNote("A tool. Note.", "Note.")
	equal(t, "A tool. Note.", once)
	equal(t, "A tool. Note.", withNote("A tool.", "Note."))
}

func TestTheGatewaysRefusalTextIsThePlainEntitlementResult(t *testing.T) {
	g, catalog := relaying(t, true)
	g.reply = m{"isError": true, "content": "O'Reilly refused this call: HTTP 403. The asker's O'Reilly account " +
		"does not include this tool."}
	text, failed := callTextRaw(t, newServer(catalog, Config{Expert: true}),
		toolCall("ask_experts", `{"question":"q"}`, personMeta))
	isTrue(t, failed, "an error")
	equal(t, noExpertAccess, text)
}

func TestWithPerPersonOnASearchThatNamesNoPersonIsNeverRemembered(t *testing.T) {
	catalog := answers([]m{book("B", "2026-01-01")}, []m{book("B", "2026-01-01")}, []m{book("B", "2026-01-01")})
	s := newServer(catalog, Config{PerPerson: true})
	for i := 0; i < 2; i++ {
		payload, _ := callText(t, rpc(t, s, toolCall("find_released", `{"topic":"x"}`, `{"timeZone":"UTC"}`)))
		isTrue(t, payload["repeat"] == nil, "no repeat note without a person")
	}
	equal(t, 2, len(catalog.calls))
}

func TestWithPerPersonOnASearchThatNamesAPersonIsRememberedForThatPersonOnly(t *testing.T) {
	catalog := answers([]m{book("B", "2026-01-01")}, []m{book("B", "2026-01-01")})
	s := newServer(catalog, Config{PerPerson: true})
	ask := func(person string) m {
		meta := `{"conversationId":"c","principalId":"` + person + `"}`
		payload, _ := callText(t, rpc(t, s, toolCall("find_released", `{"topic":"x"}`, meta)))
		return payload
	}
	isTrue(t, ask("p-1")["repeat"] == nil, "first")
	equal(t, repeatNote, ask("p-1")["repeat"])
	isTrue(t, ask("p-2")["repeat"] == nil, "another person gets their own search")
	equal(t, 2, len(catalog.calls))
}
