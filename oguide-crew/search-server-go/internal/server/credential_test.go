package server

// These tests prove the design rule: the search server holds no key. The O'Reilly credential (the
// subscriber key, or the asking person's own token through callerCredential) is added to each
// outbound request by Kubemoot's MCP gateway, so with the gateway the searches work and without it
// they fail. The fakes here play O'Reilly and the gateway; no real credential or API is involved.

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

const (
	subscriberKey = "subscriber-key-canary-7f3a"
	aliceToken    = "alice-own-token-canary-91c2"
	bobToken      = "bob-own-token-canary-44d8"
)

// fakeOReilly is the upstream catalog: it answers only a request that carries a token it knows.
type fakeOReilly struct {
	mu     sync.Mutex
	tokens map[string]bool
	seen   []string // the Authorization header of each request, "" when it had none
	srv    *httptest.Server
}

func newFakeOReilly(t *testing.T, tokens ...string) *fakeOReilly {
	t.Helper()
	f := &fakeOReilly{tokens: map[string]bool{}}
	for _, token := range tokens {
		f.tokens[token] = true
	}
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeOReilly) serve(w http.ResponseWriter, r *http.Request) {
	auth := r.Header.Get("Authorization")
	f.mu.Lock()
	f.seen = append(f.seen, auth)
	known := f.tokens[strings.TrimPrefix(auth, "Bearer ")]
	f.mu.Unlock()
	if !known {
		http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
		return
	}
	results, _ := json.Marshal(m{"search_results": m{"urn:1": book("Served By O'Reilly", "2026-01-01")}})
	_, _ = w.Write(results)
}

func (f *fakeOReilly) requests() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string{}, f.seen...)
}

// fakeGateway is the crew's MCP gateway tool endpoint. It adds the credential to the outbound
// request: the subscriber key it holds (authSecretRef), or the token leased for the asking person
// (callerCredential Required, no fallback to the key).
type fakeGateway struct {
	mu       sync.Mutex
	upstream string
	key      string            // the subscriber key from authSecretRef; empty when the gateway holds none
	leases   map[string]string // "conversationId/principalId" to the person's token; nil when not Required
	required bool
	received []gatewayCall
	srv      *httptest.Server
}

type gatewayCall struct {
	header http.Header
	body   string
}

func newFakeGateway(t *testing.T, upstream string) *fakeGateway {
	t.Helper()
	g := &fakeGateway{upstream: upstream}
	g.srv = httptest.NewServer(http.HandlerFunc(g.serve))
	t.Cleanup(g.srv.Close)
	return g
}

func (g *fakeGateway) credentialFor(meta map[string]string) (string, string) {
	if !g.required {
		return g.key, ""
	}
	token := g.leases[meta["conversationId"]+"/"+meta["principalId"]]
	if token == "" {
		return "", "No O'Reilly account is connected for this question."
	}
	return token, ""
}

func (g *fakeGateway) serve(w http.ResponseWriter, r *http.Request) {
	data, _ := io.ReadAll(r.Body)
	var request struct {
		Meta map[string]string `json:"_meta"`
	}
	_ = json.Unmarshal(data, &request)
	g.mu.Lock()
	g.received = append(g.received, gatewayCall{r.Header.Clone(), string(data)})
	token, refusal := g.credentialFor(request.Meta)
	g.mu.Unlock()
	if refusal != "" {
		reply(w, true, refusal)
		return
	}
	outbound, _ := http.NewRequest(http.MethodPost, g.upstream, bytes.NewReader(data))
	if token != "" {
		outbound.Header.Set("Authorization", "Bearer "+token)
	}
	response, err := http.DefaultClient.Do(outbound)
	if err != nil {
		reply(w, true, "Error: "+err.Error())
		return
	}
	defer func() { _ = response.Body.Close() }()
	body, _ := io.ReadAll(response.Body)
	if response.StatusCode >= http.StatusBadRequest {
		reply(w, true, "Error: HTTP "+response.Status+": "+string(body))
		return
	}
	reply(w, false, string(body))
}

// reply writes a gateway tool reply: {"isError": bool, "content": "<tool text>"}.
func reply(w http.ResponseWriter, failed bool, content string) {
	_ = json.NewEncoder(w).Encode(m{"isError": failed, "content": content})
}

func (g *fakeGateway) everything() string {
	g.mu.Lock()
	defer g.mu.Unlock()
	var all strings.Builder
	for _, got := range g.received {
		all.WriteString(got.body)
		for name, values := range got.header {
			all.WriteString(name + "=" + strings.Join(values, ",") + "\n")
		}
	}
	return all.String()
}

func search(t *testing.T, c Catalog, meta string) (m, bool) {
	t.Helper()
	return callText(t, rpc(t, newServer(c, Config{}), toolCall("find_released", `{"topic":"kubernetes"}`, meta)))
}

func TestWithTheGatewayHoldingTheSubscriberKeyTheSearchWorks(t *testing.T) {
	upstream := newFakeOReilly(t, subscriberKey)
	gateway := newFakeGateway(t, upstream.srv.URL)
	gateway.key = subscriberKey
	payload, failed := search(t, NewGatewayCatalog(gateway.srv.URL, false), "")
	isTrue(t, !failed, "the search works")
	equal(t, []string{"Served By O'Reilly"}, titles(t, payload["released"]))
	equal(t, []string{"Bearer " + subscriberKey}, upstream.requests())
}

func TestTheServerSendsTheGatewayNeitherAKeyNorAnAuthHeader(t *testing.T) {
	upstream := newFakeOReilly(t, subscriberKey)
	gateway := newFakeGateway(t, upstream.srv.URL)
	gateway.key = subscriberKey
	search(t, NewGatewayCatalog(gateway.srv.URL, false), "")
	everything := gateway.everything()
	isTrue(t, !strings.Contains(everything, subscriberKey), "the key is not in the server's request")
	for _, got := range gateway.received {
		for _, name := range []string{"Authorization", "X-Api-Key", "Cookie"} {
			equal(t, "", got.header.Get(name), name)
		}
	}
}

func TestWithoutTheGatewayAddingACredentialTheSearchFails(t *testing.T) {
	upstream := newFakeOReilly(t, subscriberKey)
	gateway := newFakeGateway(t, upstream.srv.URL) // holds no key: forwards the call without a credential
	text, failed := callTextRaw(t, newServer(NewGatewayCatalog(gateway.srv.URL, false), Config{}),
		toolCall("find_released", `{"topic":"kubernetes"}`, ""))
	isTrue(t, failed, "the search fails")
	contains(t, text, "The O'Reilly catalog could not be searched:")
	contains(t, text, "401")
	equal(t, []string{""}, upstream.requests())
}

func TestPointedStraightAtO_ReillyTheServerCannotSearch(t *testing.T) {
	upstream := newFakeOReilly(t, subscriberKey)
	text, failed := callTextRaw(t, newServer(NewGatewayCatalog(upstream.srv.URL, false), Config{}),
		toolCall("find_released", `{"topic":"kubernetes"}`, ""))
	isTrue(t, failed, "the search fails")
	contains(t, text, "HTTP 401")
	for _, auth := range upstream.requests() {
		equal(t, "", auth, "the server adds no credential of its own")
	}
}

func personGateway(t *testing.T) (*fakeOReilly, *fakeGateway) {
	t.Helper()
	upstream := newFakeOReilly(t, aliceToken, bobToken) // the subscriber key is not known here
	gateway := newFakeGateway(t, upstream.srv.URL)
	gateway.key = subscriberKey
	gateway.required = true
	gateway.leases = map[string]string{"conv-a/p-alice": aliceToken, "conv-b/p-bob": bobToken}
	return upstream, gateway
}

func TestWithCallerCredentialEachPersonSearchesWithTheirOwnToken(t *testing.T) {
	upstream, gateway := personGateway(t)
	catalog := NewGatewayCatalog(gateway.srv.URL, true)
	for _, meta := range []string{`{"conversationId":"conv-a","principalId":"p-alice"}`,
		`{"conversationId":"conv-b","principalId":"p-bob"}`} {
		_, failed := search(t, catalog, meta)
		isTrue(t, !failed, meta)
	}
	equal(t, []string{"Bearer " + aliceToken, "Bearer " + bobToken}, upstream.requests())
}

func TestAPersonsTokenNeverReachesTheServerOrItsOutput(t *testing.T) {
	_, gateway := personGateway(t)
	var out bytes.Buffer
	in := toolCall("find_released", `{"topic":"kubernetes"}`, `{"conversationId":"conv-a","principalId":"p-alice"}`) + "\n"
	_ = newServer(NewGatewayCatalog(gateway.srv.URL, true), Config{}).Serve(strings.NewReader(in), &out)
	contains(t, out.String(), "Served By O'Reilly")
	for _, secret := range []string{aliceToken, bobToken, subscriberKey} {
		isTrue(t, !strings.Contains(out.String(), secret), "no token in the server's output")
		isTrue(t, !strings.Contains(gateway.everything(), secret), "no token in the server's request")
	}
}

func TestWithoutAConnectedAccountTheSearchFailsAndNeverFallsBackToTheSharedKey(t *testing.T) {
	upstream, gateway := personGateway(t)
	catalog := NewGatewayCatalog(gateway.srv.URL, true)
	for _, meta := range []string{`{"conversationId":"conv-z","principalId":"p-nobody"}`, `{"timeZone":"UTC"}`, ``} {
		text, failed := callTextRaw(t, newServer(catalog, Config{}), toolCall("find_released", `{"topic":"x"}`, meta))
		isTrue(t, failed, "the search fails: "+meta)
		contains(t, text, "No O'Reilly account is connected")
	}
	equal(t, 0, len(upstream.requests()), "O'Reilly was never called")
}

func TestWithRelayOffACallerCredentialGatewayHasNoPersonToLease(t *testing.T) {
	upstream, gateway := personGateway(t)
	_, failed := callTextRaw(t, newServer(NewGatewayCatalog(gateway.srv.URL, false), Config{}),
		toolCall("find_released", `{"topic":"x"}`, `{"conversationId":"conv-a","principalId":"p-alice"}`))
	isTrue(t, failed, "the search fails")
	equal(t, 0, len(upstream.requests()), "O'Reilly was never called")
}

func TestAnExpertCallAlsoGoesThroughTheGatewayWithThePersonsToken(t *testing.T) {
	upstream, gateway := personGateway(t)
	catalog := NewGatewayCatalog(gateway.srv.URL, true)
	text, failed := callTextRaw(t, newServer(catalog, Config{Expert: true}),
		toolCall("ask_experts", `{"question":"q"}`, `{"conversationId":"conv-b","principalId":"p-bob"}`))
	isTrue(t, !failed, text)
	equal(t, []string{"Bearer " + bobToken}, upstream.requests())
}

func TestTheServerSourceHoldsNoCredentialHandling(t *testing.T) {
	for _, file := range sourceFiles(t) {
		for _, banned := range []string{"Authorization", "Bearer", "X-Api-Key", "Cookie", "Setenv", "ReadFile", "Open("} {
			isTrue(t, !strings.Contains(file.text, banned), file.name+" mentions "+banned)
		}
	}
}

type sourceFile struct{ name, text string }

// sourceFiles are the Go files the binary is built from, tests left out.
func sourceFiles(t *testing.T) []sourceFile {
	t.Helper()
	var files []sourceFile
	for _, pattern := range []string{"*.go", "../../cmd/oguide-search/*.go"} {
		names, err := filepath.Glob(pattern)
		if err != nil || len(names) == 0 {
			t.Fatalf("no source files for %s: %v", pattern, err)
		}
		for _, name := range names {
			if strings.HasSuffix(name, "_test.go") {
				continue
			}
			text, err := os.ReadFile(name)
			if err != nil {
				t.Fatal(err)
			}
			files = append(files, sourceFile{filepath.Base(name), string(text)})
		}
	}
	return files
}

func TestTheOnlyHeaderTheServerSetsIsTheContentType(t *testing.T) {
	for _, file := range sourceFiles(t) {
		for _, line := range strings.Split(file.text, "\n") {
			if strings.Contains(line, "Header.Set(") || strings.Contains(line, "Header.Add(") {
				contains(t, line, `"Content-Type"`)
			}
		}
	}
}
