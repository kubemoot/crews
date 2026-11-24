# oguide-crew

O'guide is a Kubemoot crew for O'Reilly subscribers who want to find their way around the O'Reilly library: what to read or watch on a topic, in what order, and which live events are coming up.

- **Who it is for:** anyone with an O'Reilly subscription and an O'Reilly MCP key, running the Kubemoot operator.
- **What it answers:** the best recent books, videos, and courses on a topic; a reading or learning path over days or weeks; upcoming live events with their session dates; what an author or publisher has published. Every item comes with its authors, content type, date, page count or duration, and a `learning.oreilly.com` reader link.
- **What it needs from the cluster:**
  - a chat model with `tool-calling` in the cluster's model catalog (a larger model with `reasoning` improves the rankings and learning paths; the chart ships no Model);
  - the O'Reilly MCP server, which the chart registers as an external MCPServer on the crew's gateway (O'Reilly hosts it; nothing is deployed for it), the crew's search server (see [The search tools](#the-search-tools)), and the workspace read-ops MCP server, which the chart deploys;
  - a Secret with your own O'Reilly key (see [Add your O'Reilly key](#add-your-oreilly-key));
  - NATS JetStream, and outbound HTTPS from the MCP gateway to `api.oreilly.com`. No database.
- **What it does not do:** unless Expert Intelligence is on (see [Expert Intelligence](#expert-intelligence-optional)), it cannot read inside the content. The O'Reilly catalog search returns metadata and links, never text from a book, video, or course, so O'guide does not quote, summarize, or explain the content; it sends you to the right item and says so when asked for more. It never answers from model memory: every item comes from the catalog search in that turn, and when the search is unavailable, fails, or finds nothing, the answer says the O'Reilly catalog could not be searched, or found nothing, and lists no titles. It stores no O'Reilly content, ships no key, and does not work without a subscriber's key.

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

## Each person's own O'Reilly access

By default the crew calls O'Reilly with one subscriber key, whoever asks. With `perPerson.enabled=true` a person who asks through a chat app signed in to O'Reilly is verified by O'Reilly itself, and the crew's O'Reilly calls carry that person's own token, so each answer reflects what that person's account includes (Expert Intelligence or only the Search MCP). It is off by default and then nothing in the chart changes.

```bash
kubectl -n crew-oguide create secret generic kubemoot-hash-key \
  --from-literal=hash-key="$(openssl rand -base64 32)"   # the same value in every door of the install
helm upgrade --install oguide oci://ghcr.io/kubemoot/charts/oguide-crew \
  --version <version> -n crew-oguide --set perPerson.enabled=true
```

Needs a Kubemoot operator that supports `Crew` `spec.discussion.access.serviceTokens` and `MCPServer` `registry.callerCredential`, and a chat app that signs people in to O'Reilly through the crew's door.

With it on:

- The Crew gets `access.serviceTokens` with one verifier named `oreilly`: the gateway tries a person's token against the O'Reilly Search MCP (`perPerson.verifier.verifyURL`, which accepts every member's token), reads the account id from `upstream_claims.sub`, and keeps the token in memory for the turn (`passToTools`). `access.hashKeySecretRef` names the installer's Secret above. The chart only names the Secret; it never holds the key.
- A second MCPServer, `oreilly-person-mcp`, serves O'Reilly's tools with `callerCredential.mode: Required`: a call carries the asking person's token and nothing else, and with no token for the turn the call fails with a message the agent reports (the subscriber key is never used on it). Its primary endpoint is the Expert MCP (`oreilly.expert.endpoint`). When that answers 403 because the account lacks the Expert entitlement, the gateway tries the Search MCP (`oreilly.endpoint`, https) with the same token for the search tool; the Expert-only tools return O'Reilly's refusal as the tool result. The subscriber key (`oreilly.auth.secretName`) lists the tools at registration and is never sent on a call.
- All three tools are always offered. `toolOverrides` on the per-person server and a note on the search server's own tools say in each description: "Results reflect the asking person's own O'Reilly access and what their account includes." (`perPerson.accessNote`). No prompt rule names a tool.
- The agents reach O'Reilly through the search server as before. The server's MCPServer sets `callerCredential.relayContext`, so the gateway passes the asker's `conversationId` and `principalId` in the call's `_meta`, and the search server passes the same two keys back on its gateway calls. The five `find_*` searches and the Expert tools therefore run as the asking person too. Nothing else from `_meta` is passed on, and a model cannot set them (they are not tool arguments).
- The Expert tools are offered whatever `oreilly.expert.enabled` says, and the Expert fitness scenarios deploy.

**No shared-key server in per-person mode** (`perPerson.keepShared`, default `false`). The chart registers only `oreilly-person-mcp`, so no per-person call can reach the shared key. Fitness runs and `kmctl` have no O'Reilly sign-in and get "connect your O'Reilly account"; run the O'guide fitness suites with `perPerson` off until tool names are scoped per server. The search server then declares no smoke input, because no person is asking.

**`perPerson.keepShared=true`** keeps the shared-key `oreilly-mcp` beside the per-person one, for an installer who knowingly accepts the risk. Both servers list the same O'Reilly tool names (`search_oreilly_content`, and with Expert `ask_oreilly_experts` and `get_oreilly_citation`), and the gateway routes a call by tool name alone, so with both registered it picks one of the two for a name and not always the same one. A call meant to be per person could then use the shared key, and a test call could be refused for want of a person.

| Value | Default | What it sets |
|---|---|---|
| `perPerson.enabled` | `false` | Turns on each person's own O'Reilly access (the Crew access block, the `oreilly-person-mcp` server, the relay and the descriptions) |
| `perPerson.keepShared` | `false` | `true` keeps the shared-key `oreilly-mcp` server beside the per-person one (see the collision warning above). `false` renders only the per-person server |
| `perPerson.verifier.name` | `oreilly` | The issuer name of the people O'Reilly vouches for. It is part of each person's id, so changing it changes every id |
| `perPerson.verifier.verifyURL` | `https://api.oreilly.com/api/search/v1/mcp` | The endpoint a person's token is tried against |
| `perPerson.verifier.subjectClaim` | `upstream_claims.sub` | The dotted path in the token's payload that names the person |
| `perPerson.verifier.audiences` | `[]` | Values the token's `aud` must have one of; omitted when empty |
| `perPerson.verifier.maxCacheSeconds` | `300` | How long an accepted token is remembered, never beyond its own expiry |
| `perPerson.hashKeySecret.name`, `.secretKey` | `kubemoot-hash-key`, `hash-key` | The installer's Secret that holds the install's hash key |
| `perPerson.accountName` | `O'Reilly` | How a refusal names the account to connect |
| `perPerson.accessNote` | see `values.yaml` | The sentence added to each tool description |

## Use O'guide from a chat app

This section covers only what is specific to O'guide. Installing the chat app, the
`ENDPOINTS: custom,agents` setting, model endpoints, creating an agent and troubleshooting are
on the Kubemoot [LibreChat page](https://kubemoot.org/docs/integrations/librechat/), and the
steps below apply to any chat app that signs in through the crew liaison.

1. **Turn on per-person access** in this chart, as in the section above:
   `--set perPerson.enabled=true`, with the `kubemoot-hash-key` Secret.
2. **Expose the crew liaison's door at its own hostname,** and turn on its sign-in front, in the
   Kubemoot chart values. The hostname is the address people sign in at and the chat app calls:

   ```yaml
   liaison:
     expose:
       enabled: true
       hostname: oguide.example.org
     auth:
       serviceTokens:
         - name: oreilly
           verifyURL: https://api.oreilly.com/api/search/v1/mcp
           verifyMethod: McpInitialize
           subjectClaim: upstream_claims.sub
           maxCacheSeconds: 300
           passToTools: true
           authorize: AnyAccepted
       hashKeySecret:
         name: kubemoot-hash-key     # the same value as in the crew namespace
     signIn:
       enabled: true
       publicURL: https://oguide.example.org
       upstream:
         authorizeURL: https://api.oreilly.com/api/search/v1/authorize
         tokenURL: https://api.oreilly.com/api/search/v1/token
         clientId: <your client id from step 3>
       sealKeySecret:
         name: liaison-signin-seal
       allowedRedirectHosts:
         - librechat.example.org     # the chat app's host; localhost is always allowed
   ```

   Both Secrets are yours to create and never go in a values file: `kubemoot-hash-key` holds one
   random value that the liaison and the crew share, and `liaison-signin-seal` holds a line
   `id:base64key` with a key from `openssl rand -base64 32`. The hostname must reach the
   liaison and nothing in front of it may require its own login: the liaison's sign-in protects
   the door.
3. **Register the door with O'Reilly as an OAuth client.** O'Reilly's MCP authorization server
   accepts dynamic client registration for a public client, with no approval step and no secret.
   Register once, with the door's callback as the redirect address, and keep the returned
   `client_id` as `signIn.upstream.clientId` (it must stay the same, because O'Reilly binds
   refresh tokens to it):

   ```bash
   curl -sS -X POST https://api.oreilly.com/api/search/v1/register \
     -H 'Content-Type: application/json' \
     -d '{"client_name": "O'"'"'guide", "redirect_uris": ["https://oguide.example.org/oauth/callback"],
          "token_endpoint_auth_method": "none",
          "grant_types": ["authorization_code", "refresh_token"],
          "response_types": ["code"], "scope": "openid offline_access"}'
   ```

   The response holds the `client_id`; it is not a secret. O'Reilly publishes no way to delete
   a registered client, so register the production hostname once rather than experimenting.
   A tool that cannot use dynamic registration can ask O'Reilly for static client credentials.
4. **Add the door to the chat app.** In `librechat.yaml`:

   ```yaml
   mcpServers:
     oguide:
       type: streamable-http
       url: https://oguide.example.org/mcp
       title: "O'guide"
       description: "Finds, compares and explains O'Reilly books, videos, courses and live events, with your own O'Reilly access."
       requiresOAuth: true
       timeout: 180000
       initTimeout: 30000
   ```

   Nothing else is configured for the sign-in: the chat app finds it from the door's 401, and
   each person signs in to O'Reilly once. The sign-in starts when the person opens the MCP panel
   and clicks Authenticate on `oguide`, not from a chat question; a browser already signed in to
   oreilly.com approves without a login page. The liaison log then shows "sign-in started",
   "sign-in completed" and an upstream token call with status 200.
5. **Give the agent instructions that keep the model from answering from memory.** Add the
   `oguide` tools to an agent and use:

   > You answer questions about O'Reilly books, videos, courses and live events. Always ask
   > the O'guide tools; never answer from your own knowledge, and never name an author, title,
   > date or link that a tool did not return. If a tool fails or returns nothing, say so.

A reply with invented authors means the model skipped the tool. A real answer lists items with
`learning.oreilly.com` links, shows a tool step in the chat, and appears as a new thread in the
Kubemoot dashboard's Moot, owned by the person's O'Reilly identity.

## Expert Intelligence (optional)

O'Reilly Expert Intelligence answers a specific technical question with grounded, citable passages from expert-authored content, where the catalog search returns only titles and links. It is a paid add-on: an O'Reilly account needs the Expert MCP entitlement (`xmcp`), and O'Reilly refuses every request to the Expert MCP of an account without it (HTTP 403), searches included. It is off by default; set `oreilly.expert.enabled=true` only with a key from an entitled account.

```bash
helm upgrade --install oguide oci://ghcr.io/kubemoot/charts/oguide-crew \
  --version <version> -n crew-oguide --set oreilly.expert.enabled=true
```

With it on:

- The gateway's O'Reilly server points at `oreilly.expert.endpoint` instead of `oreilly.endpoint`. The Expert MCP serves the same search tool, so the five search tools work unchanged.
- The search server offers two more tools, `ask_experts` (a technical question, with optional author, date range, result count and product filters; returns snippets, each with a title, authors, date, chapter, preview and reader link) and `get_citation` (the full source text of one snippet that `ask_experts` returned). The library-search agent lists them beside its search tools. They are named differently from O'Reilly's own `ask_oreilly_experts` and `get_oreilly_citation` so that they never collide with the raw tools on the gateway.
- Tool knowledge is in the tool descriptions, not in prompt rules. The crew's prompts change only in behavior: the metadata-only statements and the decline-to-quote rules give way to one rule, kept in `catalog-grounding` where every agent reads it: a claim about what content says is made only from a passage an expert tool returned in that turn, with that passage's title and link, and nothing is cited that a tool did not return.
- The fitness scenarios in `fitness/expert/` are added to the `oguide-fitness` ConfigMap, and `quote-passage-declined.adl` (which asserts the crew declines to quote) is left out.

**Why the search server wraps the Expert tools.** The agents already reach O'Reilly only through the search server, because the gateway has no per-caller allow-list and the raw tool stays out of the agents' tool lists. The Expert tools follow the same route. The search server can then turn O'Reilly's refusal into one plain tool result that the agent can report, and the gateway needs no second O'Reilly server whose tool names would collide with the first.

**An account without the entitlement.** O'Reilly answers 403 with `The 'xmcp' (Expert MCP) permission is required.` The search server returns that as an error tool result (`isError: true`), never a crash: "This O'Reilly account does not include Expert Intelligence (the Expert MCP entitlement), so the Expert tools are refused. Nothing was retrieved; say so and do not answer from memory." The same message answers a catalog search, because O'Reilly refuses those too. If the Expert MCP refuses the gateway's tool discovery, the gateway lists no tools for it and the searches fail; set `oreilly.expert.enabled` back to `false` to return to the Search MCP.

## What it deploys

| Agent | Role | Tools |
|---|---|---|
| oguide-coordinator | Plans the turn, convenes the agents a question needs, and writes the answer with a link for every item | none |
| library-search | Finds released books, videos, courses, and other recorded content on a topic, or one author's work | `find_released`, `find_by_author`, `find_title`; with Expert on, also `ask_experts` and `get_citation` |
| events-scout | Finds upcoming live events and live courses on a topic, with every session date, and books, videos, and courses announced for release | `find_live_events`, `find_scheduled`, and `execute_code` (time-zone conversion and date arithmetic with GNU `date`) |
| curator | Ranks, removes older editions, compares by recency, depth, and audience, and builds reading and learning paths | workspace read tools and `workspace_query` |
| goose-curator (optional) | A seat run by goose that searches the catalog and orders what it finds; shown as goose on the dashboard | `find_released`, `find_by_author`, `find_title` |

Also: 11 ADL PromptModules (12 with the goose seat), the Crew, its CrewSchedulingPolicy, an MCPGateway, the O'Reilly MCPServer (an external endpoint on the gateway, no deployment), the search MCPServer (the crew's search server: by default in the official Python image pinned by digest with its code in a Secret, or with `mcpServers.search.engine: go` its own static Go image pinned by digest), the workspace read-ops MCPServer that lets the curator read large search results, the code sandbox MCPServer (Kubemoot's `code-sandbox` image; no credentials, no workspace volume, egress denied by a NetworkPolicy) that events-scout calls for time-zone conversion and date arithmetic, and the fitness scenarios ConfigMap.

## The search tools

The model never builds a catalog search. The search server (`search-server/server.py`, plain Python, no dependencies) offers five tools, each with one text argument, and builds every filter, the item counts (25, and 50 for an author's books), and the order itself. It calls the raw `search_oreilly_content` tool through the crew's gateway (the gateway's tool endpoint, as agents do), so the key, the argument coercion, and the call log stay in the gateway. The agents' tool lists name only the five tools below (and, with Expert on, the two Expert tools after them); the gateway has no per-caller allow-list today, so keeping the raw tool out of the agents' `enabledTools` is what keeps them from calling it.

| Tool | Argument | Returns |
|---|---|---|
| `find_released` | `topic` | Released items on the topic, newest first |
| `find_scheduled` | `topic` | Books, videos, and courses announced but not yet released, soonest first (live events are `find_live_events`) |
| `find_by_author` | `name` | The author's books (`released_books` newest first, `scheduled_books` soonest first; up to 50 per status) and the newest items of the other formats (`released_other_formats`, `scheduled_other_formats`; up to 25 per status), keeping only items that list the author and listing an item once. The author's upcoming live events and live courses come as `upcoming_live_events` with every session date, soonest first (the catalog never lists past events, and its publication date is not a session date, so that search has no date filter). Five catalog calls: books, other formats and live events are searched on their own with their own limit, so live events and videos never crowd out books. A search that fails or reaches its limit is named in a `message` and the other lists are still returned; the tool fails only when all five searches fail. When the name matches more than one author entry as the catalog lists it (`Bruce Hopkins` and `Bruce R. Hopkins`), the result is `authors`, one group per exact author string and never merged: each group has `author`, `item_counts`, `topics` (the most common catalog tags, then the first titles, since tags are often empty), `formats`, `publishers` and the same five lists, and a `message` says the name matches more than one entry so the model asks or picks by topic. An item listing two matching strings is in both groups |
| `find_title` | `title` | One named book, video, or course, released or scheduled, best match first |
| `find_live_events` | `topic` | Upcoming live events and live courses with their session dates, soonest first (a person's name points to `find_by_author`) |

Each item has the title, authors, format, publication date, page count or duration (as text such as `10 h 31 min` or `45 s`, never raw seconds) and session dates when the catalog gives them, the reader link, and a `status` of `Released` or `Scheduled`, worked out in code from the item's own date against today's date (a live event is Scheduled while it has a session today or later; an item with no date is Released). Session dates are the catalog's dates as written and are compared with the requester's date as written, with no further time zone conversion. Nothing is invented. Author names are matched by their words: case, accents, initials (`Neal E. Ford`), suffixes and word order (`Ford, Neal`) are ignored, `Neil Ford` does not match `Neal Ford`. When a topic search is really a person's name (the topic holds an author's full name and at least three results list that author), `find_released` and `find_scheduled` answer with a pointer to `find_by_author`. A search that finds nothing answers with a plain `Nothing found for ...` message, which is not an error. The same search repeated within 20 seconds (in the same thread, when the call names one; calls that name no thread, which is every call through the gateway's tool endpoint today, share one store, so two conversations asking the identical thing within 20 seconds get the same results) answers with the same results and a `repeat` note saying it repeats an earlier search, so whichever caller of the thread (an agent, or a goose seat through its sidecar) ran it first, every caller gets the data, and a model that loops is told it is looping. The store holds at most 256 searches, oldest dropped first. If the gateway or O'Reilly cannot be reached or refuses the key, a tool answers with an MCP error result (`isError: true`) saying the catalog could not be searched, and the crew's answer says so.

### Two engines: Python or Go

The search server has two implementations with the same five tools (and the two Expert tools), the same arguments, and the same result shapes. `mcpServers.search.engine` picks one:

- `python` (the default): `search-server/server.py`, plain Python, run in the official Python image pinned by digest, its code in a Secret.
- `go`: `search-server-go/`, one static binary in an image of its own built with Paketo's Go buildpack and pinned by digest (`mcpServers.search.go.image`). No code Secret and no mounted file. It is about a third of the Python server's memory (peak 10 MiB against 29 MiB on the same recorded queries, measured locally).

Neither engine holds a key. The server process has no credential variable, Secret, or mount; the crew's MCP gateway adds the O'Reilly credential to each outbound request, the subscriber key from `oreilly.auth` or, with `perPerson`, the asking person's own token through `callerCredential`. The Go server's tests prove it: with a gateway that adds the credential the searches work, and with one that does not (or pointed straight at O'Reilly) they fail.

`engine: go` renders only with an image pinned by digest. The value in git is a placeholder (stamping it in the release is not done yet), so a render with the placeholder fails; set `--set mcpServers.search.go.image=<registry>/crews/oguide-search@sha256:<digest>` with the digest the "CI O'guide Search Server" workflow prints for the commit. To compare the engines on a running crew, use `search-server-go/cmd/oguide-compare` (see [search-server-go/README.md](search-server-go/README.md)).

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
| `oreilly.endpoint` | `https://api.oreilly.com/api/search/v1/mcp` | The O'Reilly Search MCP server, open to every O'Reilly member |
| `oreilly.expert.enabled` | `false` | Turns on [Expert Intelligence](#expert-intelligence-optional): the gateway's O'Reilly server becomes the Expert MCP, and the library-search agent gets `ask_experts` and `get_citation`. Needs an account with the Expert MCP entitlement |
| `oreilly.expert.endpoint` | `https://api.oreilly.com/api/expert/v1/mcp` | The O'Reilly Expert MCP server, used in place of `oreilly.endpoint` when `oreilly.expert.enabled` is `true` |
| `oreilly.auth.secretName` | `oreilly-mcp-auth` | The Secret that holds your key |
| `oreilly.auth.secretKey` | `bearer-token` | The key in that Secret: `bearer-token` (sent as `Authorization: Bearer`) or `api-key` |
| `oreilly.auth.header` | empty | With `api-key` only: the header that carries it |
| `imagePullSecrets` | `[]` | Pull secrets for the gateway, for a private mirror |
| `oreilly.defaultTimeZone` | `UTC` | The time zone whose date is "today" when a request carries none |
| `mcpServers.search.engine` | `python` | `python` or `go`: which search server runs |
| `mcpServers.search.image` | `python@sha256:...` | The Python image the search server runs in, pinned by digest (engine `python`) |
| `mcpServers.search.go.image` | `oguide-search@sha256:0000...` | The Go search server image, pinned by digest; the placeholder fails the render until you set it (engine `go`) |
| `mcpServers.search.go.resources` | 10m / 16Mi requests, 200m / 64Mi limits | Resources of the Go search server |
| `mcpGateway.name`, `mcpGateway.port` | `oguide-gateway`, `8080` | The gateway the search server calls (its address is built from these and the release namespace) |
| `global.imageRegistry` | `ghcr.io/kubemoot` | Registry prefix for the Kubemoot image the chart pins (`code-sandbox`); an image value that contains a `/` is used as written |
| `mcpServers.codeSandbox.enabled` | `true` | Deploys the code sandbox and gives events-scout `execute_code`. `false` removes the server, its NetworkPolicy, and the tool |
| `mcpServers.codeSandbox.image` | `code-sandbox:0.0.0` | The code sandbox image; the `0.0.0` tag is stamped at build with Kubemoot's released version |
| `mcpServers.codeSandbox.runtimeClassName` | empty | The RuntimeClass to run the sandbox pod under, for example `gvisor`; needs `transport: http` |
| `mcpServers.codeSandbox.transport` | `stdio` | `stdio` (through the operator's bridge sidecar) or `http` (Streamable HTTP, no bridge) |
| `nats.url` | `nats://nats.nats.svc.cluster.local:4222` | NATS JetStream for the discussion workspace |
| `curator.workspaceQuery` | `true` | Gives the curator `workspace_query` beside `workspace_head`, `workspace_tail` and `workspace_grep` (read-only SQL over stored search results); offered only when the Kubemoot operator's `workspace.queryEngine` is `sqlite` or `duckdb` |
| `workspace.declareAccess` | `true` | Sets `spec.workspace.access` on each agent: `write` on the search agents (they store large results and read none), `read` on the curator; the coordinator declares nothing. `false` renders no `workspace` field and no `disabledTools`, for an operator whose Agent CRD has no `spec.workspace`; the agents still list the new tool names. The operator grants the workspace tools the access allows, so the curator also gains `workspace_list` and `workspace_describe`; `curator.workspaceQuery=false` renders `disabledTools: [workspace_query]`. The curator on `read` stores none of its own tool results, so they come back inline and may be cut. Needs a workspace server that serves `workspace_head`, `workspace_tail` and `workspace_grep` |
| `gooseSeat.enabled` | `false` | Adds one extra specialist Agent run by [goose](https://kubemoot.org/docs/architecture/the-harness-seam/) (`harness: {name: goose, mode: sidecar, nativeTools: none}`). The cluster's KubemootConfig must set `images.harnessGoose`. Set it back to `false` to remove the seat |
| `gooseSeat.name` | `goose-curator` | The goose seat's Agent name |
| `crew.name` | `oguide` | The Crew's name |
| `crew.placementPolicy` | empty | `algorithm`, `learned`, or `shadow`; empty inherits the cluster default |
| `crew.discussion.access` | `{}` | Who may ask (Crew `spec.discussion.access`): `tokenReview`, `allowAnonymous`, `tokenAudiences`. Empty, every caller is anonymous. Set, the gateway checks each caller's Kubernetes token and RBAC (`get` on the Crew) decides who may use the crew, and each conversation belongs to its caller |
| `network.allowedIngress` | `[]` | Namespace label selectors whose pods may reach the crew's discussion gateway when the operator generates network policies (Crew `spec.network.allowedIngress`). Empty renders no `network` field; set it only on a Kubemoot operator that supports Crew network policies |
| `egress.mcpServers`, `egress.agents` | `{}` | Per-resource `spec.egress`, keyed by rendered name and copied as written; see [Egress](#egress) |
| `egress.agentsDefault` | unset | `spec.egress` for every Agent without its own `egress.agents` entry; `{}` limits agents to Kubemoot's automatic allows; see [Egress](#egress) |

## Egress

The `egress` value sets outbound network access for one tool server or agent at a time. Each entry is keyed by the rendered name of an MCPServer (`egress.mcpServers`) or an Agent (`egress.agents`), and its value is copied as written into that resource's `spec.egress`. A field the Kubemoot operator adds to `spec.egress` later needs no chart change. Names are the ones in `templates/`, for example `search-mcp` or `library-search`. An entry whose name matches no resource in this chart renders nothing and does not fail the install.

```yaml
egress:
  mcpServers:
    search-mcp:
      allowedHosts: ["api.example.com"]
      ports: [443]
```

This lets `search-mcp` reach `api.example.com` on port 443, plus what the operator always allows (DNS, and for an agent the bus, gateway, and model servers). It needs a Kubemoot operator with egress policies, and the operator chart flag `security.networkPolicies.egress.mode: Declared`; without the flag `spec.egress` has no effect, and a workload without `spec.egress` is never restricted. Leave `egress` empty, the default, on a Kubemoot release that has no `spec.egress` field: the chart then renders the same manifests as before. See the Kubemoot documentation page on network policies for the fields and how host names are enforced on each network plugin.

### Default egress for every agent

`egress.agentsDefault` sets one `spec.egress` for all the chart's Agents at once. Unset (the default) it changes nothing. When set, every Agent the chart renders gets it as `spec.egress`, unless `egress.agents.<name>` names that Agent: the per-agent entry then wins entirely, with no merging of fields, and the other agents keep the default. MCP servers never take the default; set them under `egress.mcpServers`.

```yaml
egress:
  agentsDefault: {}
  agents:
    some-agent:
      allowedHosts: ["api.example.com"]
      ports: [443]
```

`agentsDefault: {}` renders `egress: {}` on every Agent, which limits each one to Kubemoot's automatic allows (DNS, the bus, the crew's gateway, its model servers, the query service, and the placement service) under `security.networkPolicies.egress.mode: Declared`. An agent that needs more has its own entry, as `some-agent` does above. A non-empty default, for example an `allowedHosts` list, is copied as written. An empty per-agent entry (`{}`) also counts as naming that Agent, so it beats a non-empty default.

## Example questions

- "What is the best recent O'Reilly material on running LLM agents on Kubernetes? Include books and videos, newest first."
- "Build me a two-week learning path to understand vector databases using O'Reilly material."
- "What upcoming O'Reilly live events are there on agentic AI, and when are they?"
- "What has Neal Ford published recently on O'Reilly?"

## Fitness

`fitness/` holds eight scenarios (three more are in `fitness/expert/`, see below): recent material, an author's recent work and what is coming next, a learning path, a second learning path whose answer must be built from the results the search found, live events, an author's recent work, a request to quote a passage, which the crew declines, and a question the catalog has nothing for, whose answer must say so and name no title, date, or link. Their references name no title, so a catalog that changes does not fail them. Every other scenario also checks, without the judge, that each link in the answer starts with `https://learning.oreilly.com/`, so an answer with a title or link from model memory fails. The check is strict: the word "http" anywhere else in an answer fails it too. The chart deploys them as one ConfigMap, `oguide-fitness`, labeled `kubemoot.ai/crew` and `kubemoot.ai/fitness-kind: scenarios`; nothing runs until someone starts a run. Assemble them into one suite with [`scripts/build-suite.py`](../scripts/build-suite.py):

```bash
python3 scripts/build-suite.py oguide-crew/fitness \
  --namespace crew-oguide --crew-ref oguide --name oguide-smoke --iterations 1
```

With `oreilly.expert.enabled=true`, `fitness/expert/` holds three more, which the chart adds to the same ConfigMap only then: a technical question answered with each claim tied to a returned citation, a request to quote met only with text a citation holds, and a refused account (run it against a key without the Expert MCP entitlement) reported plainly with nothing answered from memory. The quote scenario above is left out of the ConfigMap when Expert is on. Build their suite with `scripts/build-suite.py oguide-crew/fitness/expert`.

The `REFLECTS` assertions need the [fitness crew](../kubemoot-fitness-crew/README.md).

## Tests

```bash
bash oguide-crew/tests/test-render.sh
```

## Migrating from the artifact names

Kubemoot renamed the discussion artifact store to the workspace. This chart follows; the old
egress key still applies for one release.

1. Upgrade Kubemoot first (operator chart, so the CRDs accept `workspaceAccess`), then this chart.
2. The workspace MCP server is now `workspace-mcp` (it was `artifact-readops-mcp`) and its
   template is `mcpserver-workspace.yaml`. Rename any `egress.mcpServers.artifact-readops-mcp`
   entry to `egress.mcpServers.workspace-mcp`; the old key still applies for one release and the
   install notes warn while it is set.
   An old `mcpServers.artifactReadOps.resources` replaces the whole `mcpServers.workspace.resources`
   map, it is not merged into it: set only `limits` there and the default `requests` are dropped,
   so set both or move the value to `mcpServers.workspace.resources`. `artifactReadOps.queryMemory`
   replaces `workspace.queryMemory` the same way.
3. The Kubemoot image is `workspace-access` and the MCPServer field is
   `kubemootImage: workspaceAccess`; set `images.workspaceAccess` in KubemootConfig.
4. The workspace bucket is `kubemoot_workspace`, the server reads `WORKSPACE_*` environment
   variables, and the operator setting `artifacts.queryEngine` is now `workspace.queryEngine`.
   Data in the old bucket is temporary and needs no copy.
