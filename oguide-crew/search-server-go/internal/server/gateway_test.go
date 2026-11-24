package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// stubGateway stands in for the crew's MCP gateway tool endpoint.
type stubGateway struct {
	mu     sync.Mutex
	status int
	reply  any
	raw    string
	handle func(w http.ResponseWriter, r *http.Request)
	path   string
	header http.Header
	body   m
	srv    *httptest.Server
}

func newStubGateway(t *testing.T) *stubGateway {
	t.Helper()
	g := &stubGateway{status: http.StatusOK}
	g.srv = httptest.NewServer(http.HandlerFunc(g.serve))
	t.Cleanup(g.srv.Close)
	return g
}

func (g *stubGateway) serve(w http.ResponseWriter, r *http.Request) {
	data, _ := io.ReadAll(r.Body)
	g.mu.Lock()
	g.path, g.header = r.URL.Path, r.Header.Clone()
	g.body = nil
	_ = json.Unmarshal(data, &g.body)
	status, reply, raw, handle := g.status, g.reply, g.raw, g.handle
	g.mu.Unlock()
	if handle != nil {
		handle(w, r)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if raw != "" {
		_, _ = io.WriteString(w, raw)
		return
	}
	if reply == nil {
		results, _ := json.Marshal(m{"search_results": m{"u1": book("Served", "2026-01-01")}})
		reply = m{"isError": false, "content": string(results)}
	}
	_ = json.NewEncoder(w).Encode(reply)
}

func (g *stubGateway) catalog() *GatewayCatalog { return NewGatewayCatalog(g.srv.URL+"/", false) }

func searchError(t *testing.T, c Catalog) *CatalogError {
	t.Helper()
	_, err := c.Search(m{"query": "x"})
	found, ok := asCatalogError(err)
	if !ok {
		t.Fatalf("want a catalog error, got %v", err)
	}
	return found
}

func TestTheSearchGoesToTheGatewayToolEndpointWithOnlyTheArguments(t *testing.T) {
	g := newStubGateway(t)
	found, err := g.catalog().Search(m{"query": "x", "n_items": 25})
	if err != nil {
		t.Fatal(err)
	}
	equal(t, "/tools/search_oreilly_content/call", g.path)
	equal(t, m{"arguments": m{"query": "x", "n_items": float64(25)}}, g.body)
	equal(t, "Served", found[0]["title"])
}

func TestNoKeyOrAuthHeaderIsSent(t *testing.T) {
	g := newStubGateway(t)
	_, _ = g.catalog().Search(m{"query": "x"})
	for _, name := range []string{"Authorization", "X-Api-Key", "Cookie", "Proxy-Authorization"} {
		equal(t, "", g.header.Get(name), name)
	}
	equal(t, "application/json", g.header.Get("Content-Type"))
}

func TestAToolErrorFromTheGatewayIsAClearFailure(t *testing.T) {
	g := newStubGateway(t)
	g.reply = m{"isError": true, "content": "Tool not found: search_oreilly_content"}
	equal(t, "the gateway said: Tool not found: search_oreilly_content", searchError(t, g.catalog()).Msg)
}

func TestAnUpstreamMessageWithoutResultsIsAClearFailure(t *testing.T) {
	g := newStubGateway(t)
	g.reply = m{"isError": false, "content": "Input validation error: '2' is not of type 'integer'"}
	contains(t, searchError(t, g.catalog()).Msg, "the catalog did not return results: Input validation error")
}

func TestALongUpstreamMessageIsCut(t *testing.T) {
	g := newStubGateway(t)
	g.reply = m{"isError": true, "content": strings.Repeat("x", 1000)}
	isTrue(t, len(searchError(t, g.catalog()).Msg) < 200, "the message is cut")
}

func TestAnHTTPErrorFromTheGatewayIsAClearFailure(t *testing.T) {
	g := newStubGateway(t)
	g.status = http.StatusServiceUnavailable
	contains(t, searchError(t, g.catalog()).Msg, "HTTP 503")
}

func TestARedirectIsNotFollowed(t *testing.T) {
	g := newStubGateway(t)
	g.handle = func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, "/elsewhere", http.StatusFound) }
	contains(t, searchError(t, g.catalog()).Msg, "HTTP 302")
}

func TestAnHTTP403FromTheGatewayIsTheEntitlementResult(t *testing.T) {
	g := newStubGateway(t)
	g.status = http.StatusForbidden
	found := searchError(t, g.catalog())
	isTrue(t, found.Entitlement, "entitlement")
	equal(t, noExpertAccess, found.Msg)
}

func TestAnUnreachableGatewayIsAClearFailure(t *testing.T) {
	probe, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := probe.Addr().String()
	_ = probe.Close()
	contains(t, searchError(t, NewGatewayCatalog("http://"+address, false)).Msg, "unreachable")
}

func TestAReplyThatIsNotTheGatewayShapeFails(t *testing.T) {
	for _, raw := range []string{`[]`, `"text"`, `{"nope":1}`, `{"content":null}`, `not json`, `{"content":"x"} y`} {
		g := newStubGateway(t)
		g.raw = raw
		_ = searchError(t, g.catalog())
	}
}

func TestAToolFailureReachesTheModelAsAnMCPErrorResult(t *testing.T) {
	g := newStubGateway(t)
	g.reply = m{"isError": true, "content": "Tool not found: search_oreilly_content"}
	s := newServer(g.catalog(), Config{})
	text, failed := callTextRaw(t, s, toolCall("find_released", `{"topic":"x"}`, ""))
	isTrue(t, failed, "an error result")
	isTrue(t, strings.HasPrefix(text, "The O'Reilly catalog could not be searched:"), text)
}

func TestTheReplyIsBounded(t *testing.T) {
	g := newStubGateway(t)
	g.raw = strings.Repeat("x", maxReplyBytes+1)
	contains(t, searchError(t, g.catalog()).Msg, "more than this server reads")
}

func TestAConnectionCutMidReplyIsAClearFailure(t *testing.T) {
	g := newStubGateway(t)
	g.handle = func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Length", "1000")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "part")
		if hijacker, ok := w.(http.Hijacker); ok {
			conn, _, _ := hijacker.Hijack()
			_ = conn.Close()
		}
	}
	contains(t, searchError(t, g.catalog()).Msg, "unreachable")
}

func TestASlowGatewayTimesOutAsAClearFailure(t *testing.T) {
	g := newStubGateway(t)
	release := make(chan struct{})
	g.handle = func(http.ResponseWriter, *http.Request) { <-release }
	defer close(release)
	catalog := g.catalog()
	catalog.client.Timeout = 50 * time.Millisecond
	contains(t, searchError(t, catalog).Msg, "unreachable (timeout)")
}

func TestTheClientTimeoutIsTheConstant(t *testing.T) {
	equal(t, timeout, NewGatewayCatalog("http://x", false).client.Timeout)
}

func TestTheItemsKeepTheOrderTheCatalogWroteThem(t *testing.T) {
	text := `{"search_results": {"urn:z": {"title": "Z"}, "urn:a": {"title": "A"}, "urn:m": {"title": "M"}}}`
	found, err := itemsIn(text)
	if err != nil {
		t.Fatal(err)
	}
	equal(t, []any{"Z", "A", "M"}, []any{found[0]["title"], found[1]["title"], found[2]["title"]})
}

func TestAnEmptyListOfResultsIsNothingFoundNotAnError(t *testing.T) {
	// The catalog answers an empty list, not an empty object, when it finds nothing.
	found, err := itemsIn(`{"search_results": []}`)
	if err != nil || len(found) != 0 {
		t.Fatalf("want no items and no error, got %v, %v", found, err)
	}
	g := newStubGateway(t)
	g.reply = m{"isError": false, "content": `{"search_results": []}`}
	payload, failed := callText(t, rpc(t, newServer(g.catalog(), Config{}),
		toolCall("find_live_events", `{"topic":"watermarking"}`, "")))
	isTrue(t, !failed, "not an error")
	contains(t, payload["message"].(string), "Nothing found")
}

func TestItemsInReadsAListOfItemsAndSkipsWhatIsNotAnObject(t *testing.T) {
	found, err := itemsIn(`{"search_results": [{"title": "T"}, "x"]}`)
	if err != nil {
		t.Fatal(err)
	}
	equal(t, 1, len(found))
	equal(t, "T", found[0]["title"])
}

func TestAResultThatIsNeitherListNorObjectIsRefused(t *testing.T) {
	for _, text := range []string{`{"search_results": "none"}`, `{"nope": 1}`, `[]`, `"x"`, `{"search_results": {"a":`,
		`not json`} {
		_, err := itemsIn(text)
		isTrue(t, err != nil, text)
	}
}

func TestACatalogItemThatIsNotAnObjectIsSkipped(t *testing.T) {
	found, err := itemsIn(`{"search_results": {"a": "junk", "b": {"title": "B"}}}`)
	if err != nil {
		t.Fatal(err)
	}
	equal(t, 1, len(found))
	equal(t, "B", found[0]["title"])
}

func TestOtherKeysBesideTheResultsAreSkipped(t *testing.T) {
	found, err := itemsIn(`{"meta": {"n": [1, 2]}, "search_results": {"a": {"title": "A"}}}`)
	if err != nil || len(found) != 1 {
		t.Fatalf("want one item, got %v, %v", found, err)
	}
}

func TestANumberKeepsItsWrittenForm(t *testing.T) {
	found, _ := itemsIn(`{"search_results": {"a": {"page_count": 100, "duration": 9089.0}}}`)
	text, _ := encodeJSON(found[0])
	contains(t, text, `"page_count":100`)
	contains(t, text, `"duration":9089.0`)
}

func TestFailureKindsAreNamedWithoutDetail(t *testing.T) {
	equal(t, "timeout", failureKind(context.DeadlineExceeded))
	equal(t, "connection failed", failureKind(errors.New("refused")))
}

func TestAGatewayAddressWithUserInfoSendsNoCredential(t *testing.T) {
	g := newStubGateway(t)
	address := strings.Replace(g.srv.URL, "http://", "http://user:pass@", 1)
	if _, err := NewGatewayCatalog(address, false).Search(m{"query": "x"}); err != nil {
		t.Fatal(err)
	}
	equal(t, "", g.header.Get("Authorization"))
}
