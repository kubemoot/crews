package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// buildServer builds the Go search server once and returns the binary.
func buildServer(t *testing.T) string {
	t.Helper()
	if testing.Short() {
		t.Skip("builds the search server")
	}
	binary := filepath.Join(t.TempDir(), "oguide-search")
	build := exec.Command("go", "build", "-o", binary, "../oguide-search") // #nosec G204 -- fixed arguments
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, output)
	}
	return binary
}

func compareRun(t *testing.T, args ...string) (int, string, string) {
	t.Helper()
	var out, errs bytes.Buffer
	code := run(args, &out, &errs)
	return code, out.String(), errs.String()
}

func TestTwoServersThatAnswerAlikeAreIdentical(t *testing.T) {
	binary := buildServer(t)
	code, out, errs := compareRun(t, "--python-cmd", binary, "--go-cmd", binary)
	if code != 0 {
		t.Fatalf("want 0, got %d\n%s\n%s", code, out, errs)
	}
	for _, want := range []string{"tools/list: identical", "0 same-shape, 0 different",
		"the catalog did not change between the two python runs"} {
		if !strings.Contains(out, want) {
			t.Errorf("the report lacks %q:\n%s", want, out)
		}
	}
}

func TestTheExpertQueriesAreAddedAndAnswered(t *testing.T) {
	binary := buildServer(t)
	code, out, _ := compareRun(t, "--python-cmd", binary, "--go-cmd", binary, "--expert")
	if code != 0 || !strings.Contains(out, "expert: a citation") {
		t.Fatalf("want 0 and the Expert queries, got %d\n%s", code, out)
	}
}

func TestADifferingServerIsReportedAndFailsTheRun(t *testing.T) {
	binary := buildServer(t)
	script := filepath.Join(t.TempDir(), "altered.sh")
	body := "#!/bin/sh\nexec " + binary + " | sed -u 's/Released/Shipped/g'\n"
	if err := os.WriteFile(script, []byte(body), 0o700); err != nil { // #nosec G306 -- a test script
		t.Fatal(err)
	}
	code, out, _ := compareRun(t, "--python-cmd", script, "--go-cmd", binary)
	if code != 1 || !strings.Contains(out, "DIFFERENT") {
		t.Fatalf("want 1 and a difference, got %d\n%s", code, out)
	}
}

func TestTheRunCannotStartWithoutAGoCommand(t *testing.T) {
	code, _, errs := compareRun(t)
	if code != 2 || !strings.Contains(errs, "--go-cmd is required") {
		t.Fatalf("want 2, got %d %q", code, errs)
	}
}

func TestAnUnknownFlagIsAUsageError(t *testing.T) {
	if code, _, _ := compareRun(t, "--nope"); code != 2 {
		t.Fatalf("want 2, got %d", code)
	}
}

func TestAServerThatCannotStartCannotBeCompared(t *testing.T) {
	code, _, errs := compareRun(t, "--python-cmd", "/nonexistent/server", "--go-cmd", "/nonexistent/other")
	if code != 2 || !strings.Contains(errs, "comparison:") {
		t.Fatalf("want 2, got %d %q", code, errs)
	}
}

func TestQueriesCanComeFromAFile(t *testing.T) {
	binary := buildServer(t)
	file := filepath.Join(t.TempDir(), "queries.json")
	body := `[{"name":"one","tool":"find_title","arguments":{"title":"x"},"meta":{"requestDate":"2026-11-23"}}]`
	if err := os.WriteFile(file, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	code, out, _ := compareRun(t, "--python-cmd", binary, "--go-cmd", binary, "--queries", file)
	if code != 0 || !strings.Contains(out, "1 queries: 1 identical") {
		t.Fatalf("want one identical query, got %d\n%s", code, out)
	}
	if code, _, errs := compareRun(t, "--go-cmd", binary, "--queries", "/nonexistent.json"); code != 2 ||
		!strings.Contains(errs, "queries:") {
		t.Fatalf("want 2 for a missing file, got %d %q", code, errs)
	}
}

func TestTheRecordedQueriesAreValidAndCoverEveryTool(t *testing.T) {
	queries, err := loadQueries("", false)
	if err != nil {
		t.Fatal(err)
	}
	covered := map[string]bool{}
	for _, query := range queries {
		covered[query.Tool] = true
	}
	for _, tool := range []string{"find_released", "find_scheduled", "find_by_author", "find_title", "find_live_events"} {
		if !covered[tool] {
			t.Errorf("no recorded query for %s", tool)
		}
	}
	if len(queries) < 30 {
		t.Errorf("want a recorded set of at least 30 queries, got %d", len(queries))
	}
}

func TestChildrenAreStartedWithNoCredentialInTheirEnvironment(t *testing.T) {
	t.Setenv("OREILLY_MCP_KEY", "canary-key-1")
	binary := buildServer(t)
	script := filepath.Join(t.TempDir(), "printenv.sh")
	body := "#!/bin/sh\nenv > " + filepath.Join(filepath.Dir(script), "env.txt") + "\nexec " + binary + "\n"
	if err := os.WriteFile(script, []byte(body), 0o700); err != nil { // #nosec G306 -- a test script
		t.Fatal(err)
	}
	if code, out, _ := compareRun(t, "--python-cmd", script, "--go-cmd", binary); code != 0 {
		t.Fatalf("exit %d\n%s", code, out)
	}
	seen, err := os.ReadFile(filepath.Join(filepath.Dir(script), "env.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(seen), "canary-key-1") || strings.Contains(string(seen), "OREILLY_MCP_KEY") {
		t.Errorf("the child saw a credential variable:\n%s", seen)
	}
	if !strings.Contains(string(seen), "OREILLY_GATEWAY_URL=") {
		t.Errorf("the child was not told the gateway:\n%s", seen)
	}
}
