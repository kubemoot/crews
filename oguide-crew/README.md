# oguide-crew

O'guide is a Kubemoot crew for O'Reilly subscribers who want to find their way around the O'Reilly library: what to read or watch on a topic, in what order, and which live events are coming up.

- **Who it is for:** anyone with an O'Reilly subscription and an O'Reilly MCP key, running the Kubemoot operator.
- **What it answers:** the best recent books, videos, and courses on a topic; a reading or learning path over days or weeks; upcoming live events with their session dates; what an author or publisher has published. Every item comes with its authors, content type, date, page count or duration, and a `learning.oreilly.com` reader link.
- **What it needs from the cluster:**
  - a chat model with `tool-calling` in the cluster's model catalog (a larger model with `reasoning` improves the rankings and learning paths; the chart ships no Model);
  - the O'Reilly MCP server, which the chart registers as an external MCPServer on the crew's gateway (O'Reilly hosts it; nothing is deployed for it), the crew's search server (see [The search tools](#the-search-tools)), and the artifact read-ops MCP server, which the chart deploys;
  - a Secret with your own O'Reilly key (see [Add your O'Reilly key](#add-your-oreilly-key));
  - NATS JetStream, and outbound HTTPS from the MCP gateway to `api.oreilly.com`. No database.
- **What it does not do:** it cannot read inside the content. The O'Reilly catalog search returns metadata and links, never text from a book, video, or course, so O'guide does not quote, summarize, or explain the content; it sends you to the right item and says so when asked for more. It never answers from model memory: every item comes from the catalog search in that turn, and when the search is unavailable, fails, or finds nothing, the answer says the O'Reilly catalog could not be searched, or found nothing, and lists no titles. It stores no O'Reilly content, ships no key, and does not work without a subscriber's key.

## Add your O'Reilly key

The O'Reilly MCP server is for O'Reilly subscribers. Each call carries the subscriber's own key, an O'Reilly access token, which the MCP gateway sends as `Authorization: Bearer <key>`. The key lives only in the gateway; the crew's search server and the agents never hold it. This chart never holds a key: you put yours in a Secret, and the chart names only the Secret (`oreilly.auth.secretName`, default `oreilly-mcp-auth`) and the key inside it (`oreilly.auth.secretKey`, default `bearer-token`).

1. **Create an access token.** Signed in to O'Reilly, open [learning.oreilly.com/access-tokens](https://learning.oreilly.com/access-tokens/) and create a token. Copy it; this is your key.
2. **Read how it is used.** O'Reilly's [MCP authentication documentation](https://learning.oreilly.com/apidocs/mcp/search/#section/Authentication) describes the token and the bearer header, and the [O'Reilly MCP documentation](https://learning.oreilly.com/apidocs/mcp/search/) describes the server and its search tool. Both pages render only in a browser signed in to O'Reilly.
3. **Create the Secret** in the crew namespace, before or after installing the chart:

   ```bash
   kubectl create namespace crew-oguide
   read -rs OREILLY_KEY   # paste the token; it is not echoed or kept in your shell history
   kubectl create secret generic oreilly-mcp-auth \
     --from-literal=bearer-token="$OREILLY_KEY" \
     -n crew-oguide
   unset OREILLY_KEY
   ```

   If you changed `oreilly.auth.secretName`, use that name. The default key name `bearer-token` is what O'Reilly expects: the gateway sends it as a bearer token. Set `oreilly.auth.secretKey` only if you store the key under `api-key` instead.

**Or keep the key in the operator namespace.** To manage one copy of the key for several crew namespaces, create the same Secret in the operator's namespace (`kubemoot` in the Kubemoot quickstart) and name it in the crew namespace's `kubemoot.ai/replicate-secrets` annotation. The operator copies it into the crew namespace and keeps the copy in step with the original:

```bash
read -rs OREILLY_KEY
kubectl create secret generic oreilly-mcp-auth \
  --from-literal=bearer-token="$OREILLY_KEY" -n kubemoot
unset OREILLY_KEY
kubectl annotate namespace crew-oguide kubemoot.ai/replicate-secrets=oreilly-mcp-auth
```

The annotation is a comma-separated list. If the namespace already replicates other Secrets (an image pull secret, for example), keep them in the list and overwrite it:

```bash
kubectl annotate namespace crew-oguide --overwrite \
  kubemoot.ai/replicate-secrets=my-pull-secret,oreilly-mcp-auth
```

**Rotate the key** by creating a new token at the access-tokens page and replacing the Secret where you keep it:

```bash
read -rs OREILLY_KEY   # the new token
kubectl create secret generic oreilly-mcp-auth \
  --from-literal=bearer-token="$OREILLY_KEY" -n crew-oguide \
  --dry-run=client -o yaml | kubectl apply -f -
unset OREILLY_KEY
```

With the key kept in the operator namespace, replace it there (`-n kubemoot`).

The operator watches the Secret and hands the new key to the gateway; a replicated copy follows its original. Nothing in the crew is edited, restarted, or reinstalled. Revoke the old token at O'Reilly once the new one works.

**Check that it worked.** The O'Reilly MCPServer reports whether the operator could read the key in its `CredentialReady` condition:

```bash
kubectl get mcpserver oreilly-mcp -n crew-oguide \
  -o jsonpath='{.status.conditions[?(@.type=="CredentialReady")].status} {.status.conditions[?(@.type=="CredentialReady")].reason}{"\n"}'
```

It prints the condition's status and reason. `True` means the key was read and the server is registered with the gateway. The reason `SecretNotFound` means no Secret by that name is in the crew namespace (with replication, check the annotation); `KeyMissing` means the Secret has neither a `bearer-token` nor an `api-key` key; `InvalidHeader` means `oreilly.auth.header` is not a valid header name or the key spans several lines. A key that O'Reilly rejects shows as failed searches. Then ask a first question:

```bash
kmctl conversation ask oguide "What has Neal Ford published recently on O'Reilly?" -n crew-oguide
```

A working key gives an answer that lists items with `learning.oreilly.com` links; an answer that says the catalog could not be searched points to the key.

**Never commit the key or put it in a values file.** The chart has no value for it, and a key passed with `--set` or in `-f my-values.yaml` is ignored and would still sit in your shell history or repository. Keep it only in the Secret, and treat anyone who can read Secrets in the crew or operator namespace as able to read it.

## What it deploys

| Agent | Role | Tools |
|---|---|---|
| oguide-coordinator | Plans the turn, convenes the agents a question needs, and writes the answer with a link for every item | none |
| library-search | Finds released books, videos, courses, and other recorded content on a topic, or one author's work | `find_released`, `find_by_author` |
| events-scout | Finds upcoming live events and live courses on a topic, with every session date, and books, videos, and courses announced for release | `find_live_events`, `find_scheduled` |
| curator | Ranks, removes older editions, compares by recency, depth, and audience, and builds reading and learning paths | artifact read-ops only |
| goose-curator (optional) | A seat run by goose that searches the catalog and orders what it finds; shown as goose on the dashboard | `find_released`, `find_by_author`, `find_title` |

Also: 11 ADL PromptModules (12 with the goose seat), the Crew, its CrewSchedulingPolicy, an MCPGateway, the O'Reilly MCPServer (an external endpoint on the gateway, no deployment), the search MCPServer (the crew's search server, in the official Python image pinned by digest, its code in a Secret), the artifact read-ops MCPServer that lets the curator read large search results, and the fitness scenarios ConfigMap.

## The search tools

The model never builds a catalog search. The search server (`search-server/server.py`, plain Python, no dependencies) offers five tools, each with one text argument, and builds every filter, the item counts (25, and 50 for an author's books), and the order itself. It calls the raw `search_oreilly_content` tool through the crew's gateway (the gateway's tool endpoint, as agents do), so the key, the argument coercion, and the call log stay in the gateway. The agents' tool lists name only the five tools below; the gateway has no per-caller allow-list today, so keeping the raw tool out of the agents' `enabledTools` is what keeps them from calling it.

| Tool | Argument | Returns |
|---|---|---|
| `find_released` | `topic` | Released items on the topic, newest first |
| `find_scheduled` | `topic` | Books, videos, and courses announced but not yet released, soonest first (live events are `find_live_events`) |
| `find_by_author` | `name` | The author's books (`released_books` newest first, `scheduled_books` soonest first; up to 50 per status) and the newest items of the other formats (`released_other_formats`, `scheduled_other_formats`; up to 25 per status), keeping only items that list the author and listing an item once. Four catalog calls: books and other formats are searched on their own with their own limit, so live events and videos never crowd out books. A search that fails or reaches its limit is named in a `message` and the other lists are still returned; the tool fails only when all four searches fail |
| `find_title` | `title` | One named book, video, or course, released or scheduled, best match first |
| `find_live_events` | `topic` | Upcoming live events and live courses with their session dates, soonest first |

Each item has the title, authors, format, publication date, page count or duration and session dates when the catalog gives them, the reader link, and a `status` of `Released` or `Scheduled`, worked out in code from the item's own date against today's date (a live event is Scheduled while it has a session today or later; an item with no date is Released). Session dates are the catalog's dates as written and are compared with the requester's date as written, with no further time zone conversion. Nothing is invented. Author names are matched by their words: case, accents, initials (`Neal E. Ford`), suffixes and word order (`Ford, Neal`) are ignored, `Neil Ford` does not match `Neal Ford`. When a topic search is really a person's name (the topic holds an author's full name and at least three results list that author), `find_released` and `find_scheduled` answer with a pointer to `find_by_author`. A search that finds nothing answers with a plain `Nothing found for ...` message, which is not an error. The same search repeated within 20 seconds (in the same thread, when the call names one; the gateway's tool endpoint passes none today, so two conversations asking the identical thing within 20 seconds share the guard and the second is told to try again in a few seconds) answers that it was just run, so a model that loops does not refill its context. If the gateway or O'Reilly cannot be reached or refuses the key, a tool answers with an MCP error result (`isError: true`) saying the catalog could not be searched, and the crew's answer says so.

### The requester's date

"Today" is the date of the person asking, not the server's. A tool call can carry it in the MCP request's `_meta`:

| Key | Value | Used as |
|---|---|---|
| `requestDate` | an ISO date, `YYYY-MM-DD` | the date, as given |
| `localDateTime` | the requester's local date and time, ISO 8601 without an offset, for example `2026-10-24T09:15:00` | its date part |
| `timeZone` | an IANA zone name, for example `America/Los_Angeles` | the date now in that zone |

Kubemoot sends all three on every tool call when the client (the dashboard, `kmctl conversation ask`, or an API caller) sent the person's time zone and local time; the gateway forwards them unchanged. `requestDate` wins over `localDateTime`, which wins over `timeZone`, which wins over the default zone (`oreilly.defaultTimeZone`, default `UTC`). A value that is missing or malformed is ignored. The date is never a tool argument, so the model cannot set it. Every result names the date and where it came from (`today` and `dateSource`). The date matters here, not the time of day: a request at 23:30 in `America/Los_Angeles` is still that date although UTC has rolled over.

The chart ships no Model objects. The coordinator and the curator declare `reasoning` and lean to the largest chat model in the cluster's model catalog; the search agents declare `tool-calling` and land on a medium one. One chat model with tool-calling is enough to run it.

## Install

Prerequisites are the same as for the other crews (the Kubemoot operator, NATS JetStream, and a chat model with tool-calling in the cluster's model catalog); see the [repository README](../README.md#install). The operator must forward an external MCP server's key (the `registry.authSecretRef` of an MCPServer with an `externalEndpoint`, reported in its `CredentialReady` condition) and run an MCPServer that mounts a Secret as a file (the search server). No database is needed.

Create the Secret as in [Add your O'Reilly key](#add-your-oreilly-key), then:

```bash
helm upgrade --install oguide \
  oci://ghcr.io/kubemoot/charts/oguide-crew \
  --version <version> \
  -n crew-oguide
```

## Values

| Value | Default | What it sets |
|---|---|---|
| `oreilly.endpoint` | `https://api.oreilly.com/api/content-discovery/v1/mcp/` | The O'Reilly MCP server |
| `oreilly.auth.secretName` | `oreilly-mcp-auth` | The Secret that holds your key |
| `oreilly.auth.secretKey` | `bearer-token` | The key in that Secret: `bearer-token` (sent as `Authorization: Bearer`) or `api-key` |
| `oreilly.auth.header` | empty | With `api-key` only: the header that carries it |
| `global.imageRegistry` | `ghcr.io/kubemoot` | Registry for the Kubemoot-built artifact-access image |
| `imagePullSecrets` | `[]` | Pull secrets for the gateway, for a private mirror |
| `oreilly.defaultTimeZone` | `UTC` | The time zone whose date is "today" when a request carries none |
| `mcpServers.search.image` | `python@sha256:...` | The Python image the search server runs in, pinned by digest |
| `mcpGateway.name`, `mcpGateway.port` | `oguide-gateway`, `8080` | The gateway the search server calls (its address is built from these and the release namespace) |
| `nats.url` | `nats://nats.nats.svc.cluster.local:4222` | NATS JetStream for the artifact store |
| `gooseSeat.enabled` | `false` | Adds one extra specialist Agent run by [goose](https://kubemoot.org/docs/architecture/the-harness-seam/) (`harness: {name: goose, mode: sidecar, nativeTools: none}`). The cluster's KubemootConfig must set `images.harnessGoose`. Set it back to `false` to remove the seat |
| `gooseSeat.name` | `goose-curator` | The goose seat's Agent name |
| `crew.name` | `oguide` | The Crew's name |
| `crew.placementPolicy` | empty | `algorithm`, `learned`, or `shadow`; empty inherits the cluster default |
| `network.allowedIngress` | `[]` | Namespace label selectors whose pods may reach the crew's discussion gateway when the operator generates network policies (Crew `spec.network.allowedIngress`). Empty renders no `network` field; set it only on a Kubemoot operator that supports Crew network policies |

## Example questions

- "What is the best recent O'Reilly material on running LLM agents on Kubernetes? Include books and videos, newest first."
- "Build me a two-week learning path to understand vector databases using O'Reilly material."
- "What upcoming O'Reilly live events are there on agentic AI, and when are they?"
- "What has Neal Ford published recently on O'Reilly?"

## Fitness

`fitness/` holds eight scenarios: recent material, an author's recent work and what is coming next, a learning path, a second learning path whose answer must be built from the results the search found, live events, an author's recent work, a request to quote a passage, which the crew declines, and a question the catalog has nothing for, whose answer must say so and name no title, date, or link. Their references name no title, so a catalog that changes does not fail them. Every other scenario also checks, without the judge, that each link in the answer starts with `https://learning.oreilly.com/`, so an answer with a title or link from model memory fails. The check is strict: the word "http" anywhere else in an answer fails it too. The chart deploys them as one ConfigMap, `oguide-fitness`, labeled `kubemoot.ai/crew` and `kubemoot.ai/fitness-kind: scenarios`; nothing runs until someone starts a run. Assemble them into one suite with [`scripts/build-suite.py`](../scripts/build-suite.py):

```bash
python3 scripts/build-suite.py oguide-crew/fitness \
  --namespace crew-oguide --crew-ref oguide --name oguide-smoke --iterations 1
```

The `REFLECTS` assertions need the [fitness crew](../kubemoot-fitness-crew/README.md).

## Tests

```bash
bash oguide-crew/tests/test-render.sh
```
