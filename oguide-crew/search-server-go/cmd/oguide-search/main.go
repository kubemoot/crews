// Command oguide-search is the O'guide search server: five fixed O'Reilly catalog searches (and,
// with the Expert MCP behind the gateway, two Expert tools) as an MCP server on stdin and stdout.
// The operator's bridge connects it to the crew's MCP gateway.
//
// Configuration comes from the environment:
//
//	OREILLY_GATEWAY_URL       the crew's MCP gateway, which adds the O'Reilly credential to each call
//	OREILLY_DEFAULT_TIMEZONE  IANA time zone whose date is "today" when a request carries none (UTC)
//	OREILLY_PER_PERSON        "true" when each person's own O'Reilly access is on: the note is appended to
//	                          every tool description and the asker's conversationId and principalId are
//	                          passed back on each gateway call
//	OREILLY_ACCESS_NOTE       the sentence appended with OREILLY_PER_PERSON
//	OREILLY_EXPERT            "true" when the gateway's O'Reilly server is the Expert MCP
//
// This process holds no credential and reads none: there is no key variable, Secret, or mount.
package main

import (
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/kubemoot/crews/oguide-search/internal/server"
)

func main() {
	os.Exit(run(os.Getenv, os.Stdin, os.Stdout, os.Stderr))
}

// run starts the server from the environment and returns the exit code.
func run(env func(string) string, stdin io.Reader, stdout, stderr io.Writer) int {
	gateway := env("OREILLY_GATEWAY_URL")
	if gateway == "" {
		_, _ = fmt.Fprintln(stderr, "OREILLY_GATEWAY_URL must be set")
		return 2
	}
	perPerson := strings.EqualFold(env("OREILLY_PER_PERSON"), "true")
	config := server.Config{
		DefaultZone: env("OREILLY_DEFAULT_TIMEZONE"),
		Expert:      strings.EqualFold(env("OREILLY_EXPERT"), "true"),
	}
	if perPerson {
		config.Note, config.PerPerson = env("OREILLY_ACCESS_NOTE"), true
	}
	if err := server.New(server.NewGatewayCatalog(gateway, perPerson), config).Serve(stdin, stdout); err != nil {
		_, _ = fmt.Fprintln(stderr, "oguide-search:", err)
		return 1
	}
	return 0
}
