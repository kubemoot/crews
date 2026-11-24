package main

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"strings"
	"testing"
)

// recordingGateway answers every tool call with one item and keeps what it was sent.
func recordingGateway(t *testing.T) (*httptest.Server, *strings.Builder) {
	t.Helper()
	var seen strings.Builder
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		seen.WriteString(r.URL.Path + " " + string(body) + "\n")
		for name, values := range r.Header {
			seen.WriteString(name + "=" + strings.Join(values, ",") + "\n")
		}
		_, _ = io.WriteString(w, `{"isError":false,"content":"{\"search_results\":{\"u\":{\"title\":\"One\",`+
			`\"publication_date\":\"2020-01-01\",\"url\":\"u\"}}}"}`)
	}))
	t.Cleanup(srv.Close)
	return srv, &seen
}

func env(values map[string]string) func(string) string {
	return func(key string) string { return values[key] }
}

func TestMainRefusesToStartWithoutAGatewayURL(t *testing.T) {
	var stderr bytes.Buffer
	code := run(env(nil), strings.NewReader(""), io.Discard, &stderr)
	if code != 2 || !strings.Contains(stderr.String(), "OREILLY_GATEWAY_URL must be set") {
		t.Fatalf("want exit 2 and the message, got %d %q", code, stderr.String())
	}
}

func TestMainServesMessagesFromStdinToStdout(t *testing.T) {
	srv, _ := recordingGateway(t)
	in := `{"jsonrpc":"2.0","id":1,"method":"tools/list"}` + "\n" +
		`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"find_title","arguments":{"title":"x"}}}` + "\n"
	var out bytes.Buffer
	if code := run(env(map[string]string{"OREILLY_GATEWAY_URL": srv.URL}), strings.NewReader(in), &out, io.Discard); code != 0 {
		t.Fatalf("exit %d", code)
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 2 || !strings.Contains(lines[0], "find_released") || !strings.Contains(lines[1], `\"title\":\"One\"`) {
		t.Fatalf("unexpected replies: %v", lines)
	}
}

func TestMainTurnsTheExpertToolsAndTheNoteOnFromTheEnvironment(t *testing.T) {
	srv, _ := recordingGateway(t)
	list := `{"jsonrpc":"2.0","id":1,"method":"tools/list"}` + "\n"
	var plain, person bytes.Buffer
	run(env(map[string]string{"OREILLY_GATEWAY_URL": srv.URL, "OREILLY_ACCESS_NOTE": "N."}), strings.NewReader(list),
		&plain, io.Discard)
	run(env(map[string]string{"OREILLY_GATEWAY_URL": srv.URL, "OREILLY_ACCESS_NOTE": "N.", "OREILLY_PER_PERSON": "true",
		"OREILLY_EXPERT": "TRUE"}), strings.NewReader(list), &person, io.Discard)
	if strings.Contains(plain.String(), "N.") || strings.Contains(plain.String(), "ask_experts") {
		t.Errorf("the note and the Expert tools need their switches: %s", plain.String())
	}
	if !strings.Contains(person.String(), "N.") || !strings.Contains(person.String(), "ask_experts") {
		t.Errorf("the switches turn them on: %s", person.String())
	}
}

func TestMainReadsNoCredentialFromTheEnvironment(t *testing.T) {
	canaries := map[string]string{"OREILLY_MCP_KEY": "canary-key-1", "OREILLY_API_KEY": "canary-key-2",
		"OREILLY_TOKEN": "canary-token-3", "AUTHORIZATION": "canary-auth-4", "API_KEY": "canary-key-5",
		"OREILLY_MCP_HEADER": "canary-header-6"}
	for name, value := range canaries {
		t.Setenv(name, value)
	}
	srv, seen := recordingGateway(t)
	t.Setenv("OREILLY_GATEWAY_URL", srv.URL)
	in := `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"find_title","arguments":{"title":"x"}}}` + "\n"
	var out bytes.Buffer
	if code := run(os.Getenv, strings.NewReader(in), &out, io.Discard); code != 0 {
		t.Fatalf("exit %d", code)
	}
	for _, value := range canaries {
		if strings.Contains(seen.String(), value) || strings.Contains(out.String(), value) {
			t.Errorf("the credential %s reached the gateway or the output", value)
		}
	}
}

func TestMainReadsOnlyTheFiveNamedVariables(t *testing.T) {
	source, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	found := map[string]bool{}
	for _, match := range regexp.MustCompile(`env\("([A-Z_]+)"\)`).FindAllStringSubmatch(string(source), -1) {
		found[match[1]] = true
	}
	want := []string{"OREILLY_GATEWAY_URL", "OREILLY_DEFAULT_TIMEZONE", "OREILLY_PER_PERSON", "OREILLY_ACCESS_NOTE",
		"OREILLY_EXPERT"}
	if len(found) != len(want) {
		t.Errorf("want exactly %v, found %v", want, found)
	}
	for _, name := range want {
		if !found[name] {
			t.Errorf("%s is not read", name)
		}
	}
	for _, banned := range []string{"os.Environ", "LookupEnv", "ReadFile", "os.Open"} {
		if strings.Contains(string(source), banned) {
			t.Errorf("main.go uses %s", banned)
		}
	}
}
