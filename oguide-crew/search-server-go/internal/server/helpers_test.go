package server

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

const today = "2026-10-20"

var now = time.Date(2026, 10, 20, 12, 0, 0, 0, time.UTC)

type m = map[string]any

func jsonNumber(text string) json.Number { return json.Number(text) }

func list(values ...string) []any {
	out := make([]any, 0, len(values))
	for _, v := range values {
		out = append(out, v)
	}
	return out
}

// merge returns base with each extra map laid over it.
func merge(base m, extras ...m) m {
	out := m{}
	for k, v := range base {
		out[k] = v
	}
	for _, extra := range extras {
		for k, v := range extra {
			out[k] = v
		}
	}
	return out
}

func book(title, date string, extra ...m) m {
	item := m{"title": title, "authors": list("A. Author"), "marketing_type": "book", "publication_date": date,
		"url":        "https://learning.oreilly.com/library/view/-/" + strings.ReplaceAll(title, " ", "") + "/",
		"page_count": json.Number("100")}
	return merge(item, extra...)
}

func event(title string, sessions []string, extra ...m) m {
	item := m{"title": title, "authors": list("E. Teacher"), "marketing_type": "live course",
		"publication_date": "2026-08-01", "live_event_start_dates": list(sessions...),
		"url": "https://learning.oreilly.com/live-events/-/" + strings.ReplaceAll(title, " ", "") + "/"}
	return merge(item, extra...)
}

func by(item m, authors ...string) m {
	return merge(item, m{"authors": list(authors...)})
}

// fakeCatalog answers each search with the next prepared list and records the arguments.
type fakeCatalog struct {
	answers [][]m
	calls   []m
	err     error
	failing map[int]bool
}

func answers(lists ...[]m) *fakeCatalog { return &fakeCatalog{answers: lists} }

func failing(err error) *fakeCatalog { return &fakeCatalog{err: err} }

// failingNth fails the calls numbered in failing (from 1) with a catalog error.
func failingNth(numbers []int, lists ...[]m) *fakeCatalog {
	set := map[int]bool{}
	for _, n := range numbers {
		set[n] = true
	}
	return &fakeCatalog{answers: lists, failing: set}
}

func (f *fakeCatalog) Search(arguments map[string]any) ([]map[string]any, error) {
	f.calls = append(f.calls, arguments)
	var next []m
	if len(f.answers) > 0 {
		next, f.answers = f.answers[0], f.answers[1:]
	}
	if f.err != nil {
		return nil, f.err
	}
	if f.failing[len(f.calls)] {
		return nil, catalogErr("boom")
	}
	return next, nil
}

func (f *fakeCatalog) Call(string, map[string]any) (string, error) {
	return "", catalogErr("not an expert catalog")
}

// recordingCatalog answers Expert tool calls with a prepared text, or fails them, and records them.
type recordingCatalog struct {
	text  string
	err   error
	calls []expertCall
}

type expertCall struct {
	tool      string
	arguments m
}

func (r *recordingCatalog) Search(map[string]any) ([]map[string]any, error) { return nil, nil }

func (r *recordingCatalog) Call(tool string, arguments map[string]any) (string, error) {
	r.calls = append(r.calls, expertCall{tool, arguments})
	return r.text, r.err
}

// decoded is the JSON an object marshals to, read back as plain values.
func decoded(t *testing.T, value any) m {
	t.Helper()
	text, err := encodeJSON(value)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	var out m
	if err := json.Unmarshal([]byte(text), &out); err != nil {
		t.Fatalf("decode %s: %v", text, err)
	}
	return out
}

func titles(t *testing.T, value any) []string {
	t.Helper()
	items, _ := value.([]any)
	out := make([]string, 0, len(items))
	for _, item := range items {
		fields, _ := item.(m)
		title, _ := fields["title"].(string)
		out = append(out, title)
	}
	return out
}

func equal(t *testing.T, want, got any, what ...string) {
	t.Helper()
	wantText, _ := json.Marshal(want)
	gotText, _ := json.Marshal(got)
	if string(wantText) != string(gotText) {
		t.Errorf("%s: want %s, got %s", strings.Join(what, " "), wantText, gotText)
	}
}

func isTrue(t *testing.T, ok bool, what ...string) {
	t.Helper()
	if !ok {
		t.Errorf("not true: %s", strings.Join(what, " "))
	}
}

func contains(t *testing.T, text, part string) {
	t.Helper()
	if !strings.Contains(text, part) {
		t.Errorf("%q does not contain %q", text, part)
	}
}

// mustParse reads the JSON-RPC text of a message the way the serve loop does.
func mustParse(t *testing.T, text string) any {
	t.Helper()
	var message any
	if err := decodeJSON([]byte(text), &message); err != nil {
		t.Fatalf("parse %s: %v", text, err)
	}
	return message
}

func newServer(catalog Catalog, config Config) *Server {
	if config.Now == nil {
		config.Now = func() time.Time { return now }
	}
	return New(catalog, config)
}

// rpc runs one JSON-RPC message and returns the reply as plain values.
func rpc(t *testing.T, s *Server, text string) m {
	t.Helper()
	reply, err := s.Handle(mustParse(t, text))
	if err != nil {
		t.Fatalf("handle: %v", err)
	}
	if reply == nil {
		return nil
	}
	return decoded(t, reply)
}

// callText is the decoded payload of a tools/call result, with whether it was an error.
func callText(t *testing.T, reply m) (m, bool) {
	t.Helper()
	result, _ := reply["result"].(m)
	content, _ := result["content"].([]any)
	if len(content) != 1 {
		t.Fatalf("no content in %v", reply)
	}
	text, _ := content[0].(m)["text"].(string)
	var payload m
	_ = json.Unmarshal([]byte(text), &payload)
	failed, _ := result["isError"].(bool)
	return payload, failed
}

// toolCall is a tools/call message.
func toolCall(name, argument, meta string) string {
	text := `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"` + name + `","arguments":` + argument
	if meta != "" {
		text += `,"_meta":` + meta
	}
	return text + `}}`
}
