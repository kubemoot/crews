// Command oguide-compare runs the Python and the Go O'guide search servers on the same recorded
// queries and reports how their answers differ.
//
// Both servers are started as child processes with an environment that holds only PATH, the
// gateway address, and the default time zone (no key, no token), so neither can rely on a credential
// in its own process. By default both call a built-in fixture gateway whose answers are a fixed
// function of the search arguments: every difference is then the servers' own and the result must
// be identical. With --gateway they call a real crew gateway (a port-forward to it); the catalog
// then answers from O'Reilly, so the Python server runs twice to show what the catalog changes by
// itself, and those queries are compared on their shape and stable fields only.
//
// Exit status: 0 when every answer matches, 1 when any differs, 2 when the comparison could not run.
package main

import (
	_ "embed" // the recorded queries travel inside the binary
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http/httptest"
	"os"
	"strings"

	"github.com/kubemoot/crews/oguide-search/internal/compare"
)

//go:embed queries.json
var recordedQueries []byte

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

type settings struct {
	pythonCmd, goCmd, gateway, queries, zone string
	expert                                   bool
}

func parseFlags(args []string, stderr io.Writer) (settings, error) {
	var s settings
	flags := flag.NewFlagSet("oguide-compare", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.StringVar(&s.pythonCmd, "python-cmd", "python3 -I oguide-crew/search-server/server.py",
		"the command that starts the Python server")
	flags.StringVar(&s.goCmd, "go-cmd", "", "the command that starts the Go server (the oguide-search binary)")
	flags.StringVar(&s.gateway, "gateway", "", "a crew gateway both servers call; empty uses the built-in fixture")
	flags.StringVar(&s.queries, "queries", "", "a JSON file of queries instead of the recorded set")
	flags.StringVar(&s.zone, "timezone", "UTC", "OREILLY_DEFAULT_TIMEZONE for both servers")
	flags.BoolVar(&s.expert, "expert", false, "turn on the Expert tools and add their queries")
	if err := flags.Parse(args); err != nil {
		return s, err
	}
	if s.goCmd == "" {
		return s, fmt.Errorf("--go-cmd is required")
	}
	return s, nil
}

func loadQueries(path string, expert bool) ([]compare.Query, error) {
	data := recordedQueries
	if path != "" {
		var err error
		if data, err = os.ReadFile(path); err != nil {
			return nil, err
		}
	}
	var queries []compare.Query
	if err := json.Unmarshal(data, &queries); err != nil {
		return nil, err
	}
	if expert {
		queries = append(queries, expertQueries()...)
	}
	return queries, nil
}

func expertQueries() []compare.Query {
	meta := map[string]any{"requestDate": "2026-11-23"}
	return []compare.Query{
		{Name: "expert: a question", Tool: "ask_experts", Meta: meta,
			Arguments: map[string]any{"question": "How do I size a Kubernetes operator's memory?", "max_results": 3}},
		{Name: "expert: a citation", Tool: "get_citation", Meta: meta,
			Arguments: map[string]any{"product_id": "9781098139575", "offset": 662}},
		{Name: "expert: a refused question", Tool: "ask_experts", Meta: meta, Arguments: map[string]any{"question": " "}},
	}
}

func run(args []string, stdout, stderr io.Writer) int {
	s, err := parseFlags(args, stderr)
	if err != nil {
		_, _ = fmt.Fprintln(stderr, err)
		return 2
	}
	queries, err := loadQueries(s.queries, s.expert)
	if err != nil {
		_, _ = fmt.Fprintln(stderr, "queries:", err)
		return 2
	}
	gateway := s.gateway
	if gateway == "" {
		fixture := httptest.NewServer(compare.Fixture{})
		defer fixture.Close()
		gateway = fixture.URL
	}
	options := compare.Options{Python: strings.Fields(s.pythonCmd), Go: strings.Fields(s.goCmd), Gateway: gateway,
		Zone: s.zone, Expert: s.expert}
	report, err := compare.Compare(options, os.Getenv("PATH"), queries)
	if err != nil {
		_, _ = fmt.Fprintln(stderr, "comparison:", err)
		return 2
	}
	report.Write(stdout)
	if report.Failed() {
		return 1
	}
	return 0
}
