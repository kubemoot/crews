# O'guide search server in Go

The Go version of the O'guide search server (`../search-server/server.py` is the Python one). It is
an MCP server on stdin and stdout with the same tools, arguments, and results:

| Tool | Argument | Offered |
|---|---|---|
| `find_released` | `topic` | always |
| `find_scheduled` | `topic` | always |
| `find_by_author` | `name` | always |
| `find_title` | `title` | always |
| `find_live_events` | `topic` | always |
| `ask_experts` | `question` (and optional filters) | with `OREILLY_EXPERT=true` |
| `get_citation` | `product_id`, `offset` | with `OREILLY_EXPERT=true` |

Tool names, descriptions, and input schemas are copied word for word into
`internal/server/tools.json`; the comparison below checks them against the Python server.

## It holds no key

The process has no credential. It reads five plain variables and nothing else:

| Variable | Meaning |
|---|---|
| `OREILLY_GATEWAY_URL` | the crew's MCP gateway (required) |
| `OREILLY_DEFAULT_TIMEZONE` | the zone whose date is "today" when a request carries none (default `UTC`) |
| `OREILLY_PER_PERSON` | `true` appends `OREILLY_ACCESS_NOTE` to every tool description and passes the asker's `conversationId` and `principalId` back on each gateway call |
| `OREILLY_ACCESS_NOTE` | the sentence appended with `OREILLY_PER_PERSON` |
| `OREILLY_EXPERT` | `true` offers the two Expert tools |

Every search goes to `POST <gateway>/tools/search_oreilly_content/call`. The gateway adds the
O'Reilly credential to its outbound request: the subscriber key from the MCPServer's
`authSecretRef`, or the asking person's own token through `callerCredential`. The server sends
only `Content-Type`. The tests (`internal/server/credential_test.go`, `cmd/oguide-search`) use a
fake O'Reilly and a fake gateway to show that the searches work through a gateway that adds the
credential, fail through one that does not and when pointed straight at O'Reilly, never fall back to
a shared key for a person without a connected account, never carry a token in the server's request or
output, and that the source contains no credential handling.

## Tests and lint

```sh
cd oguide-crew/search-server-go
go test -race ./...
../../.github/scripts/golangci-lint.sh      # the shared .golangci.yml, cyclomatic complexity at most 10
```

The tests port every case of the Python `test_server.py` (dates, ordering, names, authors, repeats,
the gateway client, the Expert tools, per-person relay) and add the Go-only ones (JSON-RPC over a
pipe, panics, ordered decoding, the credential rule).

## How the asker's ids reach the server

With `OREILLY_PER_PERSON` the server passes `conversationId` and `principalId` from the call's
`_meta` back on its gateway calls, so the gateway can lease that person's token for the inner
`search_oreilly_content` call. The agent runtime puts both in `_meta`. The search server is mode
`Off` with `registry.callerCredential.relayContext: true`, and the gateway keeps the two ids in the
`_meta` it forwards to a server with `relayContext`, in mode `Off` as in mode `Required`. The server
keeps its own credential; the ids are handles, never a token. This needs a Kubemoot gateway and
operator with that support (kubemoot PR "relayContext forwards the asking person's ids to a server
in mode Off"). Without it the ids are cut from `_meta`, an inner call carries no person, and a
`Required` per-person server answers "no account connected"; the server then falls back safely: with
per-person on, a search that names no person is never remembered or answered from memory.

What is forwarded, exactly: on every gateway call (`POST <gateway>/tools/<tool>/call`, the
five searches including each call of an author search, and both Expert tools) the body is
`{"arguments": {...}, "_meta": {"conversationId": "...", "principalId": "..."}}`, the same body the
Python server sends. Only those two keys, only when the incoming `_meta` holds them as non-empty text
of at most 256 characters, and never anything from `arguments`. A request whose `_meta` names neither
sends no `_meta`, and the gateway then refuses the inner call ("carried no conversation and
principal"); that refusal is correct, since no person asked. The context is read from each request
and never kept, so one person's ids never ride on the next person's call
(`internal/server/relay_test.go` and `perperson_test.go`).

If the gateway logs that refusal for a call that came from a person, the ids were already missing
when the call reached this server: check that the MCPServer registers `callerCredential.relayContext`
and that the gateway and operator are new enough to keep the ids for a mode `Off` server.

## Differences from the Python server

- The repeat memory keys on the asking person (`principalId`) as well as the thread, so one person's
  repeated search is never answered with another person's results. With `OREILLY_PER_PERSON` on, a
  search whose `_meta` names no person is neither remembered nor answered from memory.
- Arguments of the Expert tools are checked in name order, not the caller's order.
- Output JSON is compact; the gateway address never carries a user name or password.
- An item with a malformed date, session list, or relevance score fails the search as a whole.

## Image and release

The "CI O'guide Search Server" workflow tests and lints the module, builds a static binary
(`.github/scripts/go-build-static.sh`), and packages it with Paketo buildpacks (the Procfile
buildpack, run image `run-static`) as `crews/oguide-search:<commit>` in Harbor. The binary is
`/workspace/oguide-search`, started directly with no shell. Nothing in the module, the image, or git
holds a version or a digest. The oguide-crew release workflow calls it on every push to main, tags the
build with the chart's version, and stamps the chart with its digest; Publish Release copies the image
to the release registry by digest with the chart's final (see the chart README).

## Comparing it with the Python server

`cmd/oguide-compare` starts both servers as child processes with an environment of only `PATH`,
the gateway address, and the time zone, sends them the same recorded queries
(`cmd/oguide-compare/queries.json`: every tool, the date sources, the refusals, a repeat), and
reports each as identical, same-shape, or DIFFERENT. It compares the `tools/list` result too.
Exit status is 0 when every answer matches, 1 when one differs, 2 when it could not run.

```sh
cd oguide-crew/search-server-go
go build -o /tmp/oguide-search ./cmd/oguide-search
go run ./cmd/oguide-compare --go-cmd /tmp/oguide-search \
  --python-cmd "python3 -I ../search-server/server.py"
```

Without `--gateway`, both servers call a built-in fixture gateway whose answers are a fixed function
of the search arguments, so the answers must be identical (this is the parity check of the
transformation, and it needs no network or credential).

Against a crew, port-forward its gateway and pass it (the gateway adds the credential; the script
never sees one):

```sh
kubectl -n crew-oguide port-forward svc/oguide-gateway 8080:8080 &
go run ./cmd/oguide-compare --go-cmd /tmp/oguide-search \
  --python-cmd "python3 -I ../search-server/server.py" --gateway http://127.0.0.1:8080
```

What varies against O'Reilly's own API: the catalog answers from live data, so a result can change
between two calls (new items, a changed ordering of equal scores, relevance scores). The Python
server therefore runs twice. A query whose two Python runs differ is "same-shape": only the keys,
value types, the date the servers worked out (`today`, `dateSource`), the fields each item uses, and
the items present in both answers (compared in full and in the same relative order) are compared.
The report lists those queries and what changed. The text of the two servers also differs in spacing
(Python writes `", "` and `": "`, Go writes compact JSON), which the comparison ignores because it
compares decoded JSON. Errors and protocol errors are compared as exact text.
