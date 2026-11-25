package server

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

// recordingGateway answers every call with an empty result and keeps the _meta of each one.
type recordingGateway struct {
	mu    sync.Mutex
	metas []any
	srv   *httptest.Server
}

func newRecordingGateway(t *testing.T) *recordingGateway {
	t.Helper()
	g := &recordingGateway{}
	g.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(r.Body)
		var body m
		_ = json.Unmarshal(data, &body)
		g.mu.Lock()
		g.metas = append(g.metas, body["_meta"])
		g.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(m{"isError": false, "content": `{"search_results": []}`})
	}))
	t.Cleanup(g.srv.Close)
	return g
}

func (g *recordingGateway) seen() []any {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]any(nil), g.metas...)
}

var everyTool = []struct{ name, arguments string }{
	{"find_released", `{"topic":"go"}`},
	{"find_scheduled", `{"topic":"go"}`},
	{"find_by_author", `{"name":"Ada Lovelace"}`},
	{"find_title", `{"title":"Learning Go"}`},
	{"find_live_events", `{"topic":"go"}`},
	{"ask_experts", `{"question":"why"}`},
	{"get_citation", `{"product_id":"123","offset":0}`},
}

func TestEveryGatewayCallOfEveryToolCarriesBothRelayedIds(t *testing.T) {
	for _, tool := range everyTool {
		t.Run(tool.name, func(t *testing.T) {
			g := newRecordingGateway(t)
			s := newServer(NewGatewayCatalog(g.srv.URL, true), Config{Expert: true, PerPerson: true})
			rpc(t, s, toolCall(tool.name, tool.arguments, personMeta))
			calls := g.seen()
			isTrue(t, len(calls) > 0, "the tool called the gateway")
			for _, meta := range calls {
				equal(t, m{"conversationId": "conv-1", "principalId": "p-abc"}, meta)
			}
		})
	}
}

func TestNoGatewayCallCarriesAnIdWhenTheRequestNamesNone(t *testing.T) {
	for _, tool := range everyTool {
		t.Run(tool.name, func(t *testing.T) {
			g := newRecordingGateway(t)
			s := newServer(NewGatewayCatalog(g.srv.URL, true), Config{Expert: true, PerPerson: true})
			rpc(t, s, toolCall(tool.name, tool.arguments, `{"timeZone":"UTC"}`))
			rpc(t, s, toolCall(tool.name, tool.arguments, ""))
			for _, meta := range g.seen() {
				isTrue(t, meta == nil, "no _meta without the relayed ids")
			}
		})
	}
}

func TestAnIdTheRequestDoesNotNameIsNotInventedForTheGateway(t *testing.T) {
	g := newRecordingGateway(t)
	s := newServer(NewGatewayCatalog(g.srv.URL, true), Config{PerPerson: true})
	rpc(t, s, toolCall("find_title", `{"title":"x"}`, `{"principalId":"p-only"}`))
	for _, meta := range g.seen() {
		equal(t, m{"principalId": "p-only"}, meta)
	}
}
