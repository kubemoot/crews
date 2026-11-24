package compare

import (
	"fmt"
	"io"
	"sort"
	"strings"
)

// Options say what to run.
type Options struct {
	Python  []string // the command that starts the Python server
	Go      []string // the command that starts the Go server
	Gateway string   // the gateway both servers call
	Zone    string   // OREILLY_DEFAULT_TIMEZONE
	Expert  bool     // OREILLY_EXPERT, with the Expert queries
}

// Run holds everything one server answered: its tool listing and an answer per query.
type Run struct {
	Tools   any
	Answers []Answer
}

// environment is all a server is given: where the gateway is, the default time zone, and PATH. It
// holds no key or token, and neither server may need one.
func environment(options Options, path string) []string {
	env := []string{"PATH=" + path, "OREILLY_GATEWAY_URL=" + options.Gateway, "OREILLY_DEFAULT_TIMEZONE=" + options.Zone}
	if options.Expert {
		env = append(env, "OREILLY_EXPERT=true")
	}
	return env
}

// Execute runs every query against one server, in a fresh process.
func Execute(command []string, env []string, queries []Query) (Run, error) {
	server, err := Start(command, env)
	if err != nil {
		return Run{}, err
	}
	defer server.Stop()
	if err := server.Initialize(); err != nil {
		return Run{}, fmt.Errorf("%s: %w", command[0], err)
	}
	tools, err := server.Tools()
	if err != nil {
		return Run{}, fmt.Errorf("%s: %w", command[0], err)
	}
	run := Run{Tools: tools}
	for _, query := range queries {
		run.Answers = append(run.Answers, server.Call(query))
	}
	return run, nil
}

// Report is the comparison of the two servers on every query.
type Report struct {
	ToolsMatch  bool
	ToolsDetail []string
	Results     []Result
}

// Compare runs the Python server twice and the Go server once on the queries. The second Python run
// shows what the catalog changes by itself.
func Compare(options Options, path string, queries []Query) (Report, error) {
	env := environment(options, path)
	python, err := Execute(options.Python, env, queries)
	if err != nil {
		return Report{}, err
	}
	again, err := Execute(options.Python, env, queries)
	if err != nil {
		return Report{}, err
	}
	goRun, err := Execute(options.Go, env, queries)
	if err != nil {
		return Report{}, err
	}
	report := Report{ToolsDetail: limit(diff("tools", python.Tools, goRun.Tools, false))}
	report.ToolsMatch = len(report.ToolsDetail) == 0
	for i, query := range queries {
		report.Results = append(report.Results, Classify(query, python.Answers[i], again.Answers[i], goRun.Answers[i]))
	}
	return report, nil
}

// Failed is true when the tool listings differ or a query got a different answer.
func (r Report) Failed() bool {
	if !r.ToolsMatch {
		return true
	}
	for _, result := range r.Results {
		if result.Verdict == Different {
			return true
		}
	}
	return false
}

// Write prints the table, what varied between the two Python runs, and the differences.
func (r Report) Write(out io.Writer) {
	_, _ = fmt.Fprintf(out, "tools/list: %s\n", map[bool]string{true: "identical", false: "DIFFERENT"}[r.ToolsMatch])
	for _, line := range r.ToolsDetail {
		_, _ = fmt.Fprintf(out, "    %s\n", line)
	}
	counts := map[Verdict]int{}
	for _, result := range r.Results {
		counts[result.Verdict]++
		_, _ = fmt.Fprintf(out, "%-11s %-18s %s\n", result.Verdict, result.Query.Tool, result.Query.Name)
		for _, line := range result.Details {
			_, _ = fmt.Fprintf(out, "    %s\n", line)
		}
	}
	_, _ = fmt.Fprintf(out, "\n%d queries: %d identical, %d same-shape, %d different\n", len(r.Results),
		counts[Identical], counts[SameShape], counts[Different])
	r.writeVaries(out)
}

// writeVaries names what changed between the two Python runs, which is the catalog and not a
// server: those queries are compared on their shape and stable fields only.
func (r Report) writeVaries(out io.Writer) {
	var names []string
	for _, result := range r.Results {
		if len(result.Varies) > 0 {
			names = append(names, fmt.Sprintf("%s (%s)", result.Query.Name, strings.Join(firstOf(result.Varies, 2), "; ")))
		}
	}
	if len(names) == 0 {
		_, _ = fmt.Fprintln(out, "the catalog did not change between the two python runs")
		return
	}
	sort.Strings(names)
	_, _ = fmt.Fprintf(out, "the catalog changed between the two python runs for %d queries, compared on shape and "+
		"stable fields only:\n", len(names))
	for _, name := range names {
		_, _ = fmt.Fprintf(out, "    %s\n", name)
	}
}

func firstOf(list []string, n int) []string {
	if len(list) > n {
		return list[:n]
	}
	return list
}
