# oguide-crew

O'guide is a Kubemoot crew for O'Reilly subscribers who want to find their way around the O'Reilly library: what to read or watch on a topic, in what order, and which live events are coming up.

- **Who it is for:** anyone with an O'Reilly subscription and an O'Reilly MCP key, running the Kubemoot operator.
- **What it answers:** the best recent books, videos, and courses on a topic; a reading or learning path over days or weeks; upcoming live events with their session dates; what an author or publisher has published. Every item comes with its authors, content type, date, page count or duration, and a `learning.oreilly.com` reader link.
- **What it needs from the cluster:**
  - a chat model with `tool-calling` in the cluster's model catalog (a larger model with `reasoning` improves the rankings and learning paths; the chart ships no Model);
  - the O'Reilly MCP server, which the chart registers as an external MCPServer (O'Reilly hosts it; nothing is deployed for it), and the artifact read-ops MCP server, which the chart deploys;
  - a Secret with your own O'Reilly key (see [Add your O'Reilly key](#add-your-oreilly-key));
  - NATS JetStream, and outbound HTTPS from the MCP gateway to `api.oreilly.com`. No database.
- **What it does not do:** it cannot read inside the content. The O'Reilly catalog search returns metadata and links, never text from a book, video, or course, so O'guide does not quote, summarize, or explain the content; it sends you to the right item and says so when asked for more. It never answers from model memory: every item comes from the catalog search in that turn, and when the search is unavailable, fails, or finds nothing, the answer says the O'Reilly catalog could not be searched, or found nothing, and lists no titles. It stores no O'Reilly content, ships no key, and does not work without a subscriber's key.

## Add your O'Reilly key

The O'Reilly MCP server is for O'Reilly subscribers. Each call carries the subscriber's own key, an O'Reilly access token, which the MCP gateway sends as `Authorization: Bearer <key>`. This chart never holds a key: you put yours in a Secret, and the chart names only the Secret (`oreilly.auth.secretName`, default `oreilly-mcp-auth`) and the key inside it (`oreilly.auth.secretKey`, default `bearer-token`).

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

   If you changed `oreilly.auth.secretName`, use that name. The default key name `bearer-token` is what O'Reilly expects: the operator sends it as a bearer token. Set `oreilly.auth.secretKey` only if you store the key under `api-key` instead.

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

The operator watches the Secret and hands the new key to the gateway; a replicated copy follows its original. Nothing in the crew is edited or reinstalled. Revoke the old token at O'Reilly once the new one works.

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
| library-search | Turns the question into several focused keyword searches with filters (content type, author, publisher, recency); returns released items only (every search is filtered to dates up to today) | `search_oreilly_content`, `get_current_time` |
| events-scout | Finds upcoming live events and live courses on a topic, with every session date, and books, videos, and courses scheduled for release (searches filtered to dates from today) | `search_oreilly_content`, `get_current_time` |
| curator | Ranks, removes older editions, compares by recency, depth, and audience, and builds reading and learning paths | artifact read-ops only |

Also: 11 ADL PromptModules, the Crew, its CrewSchedulingPolicy, an MCPGateway, the O'Reilly MCPServer (an external endpoint, no deployment), the artifact read-ops MCPServer that lets the curator read large search results, the Time MCPServer (the MCP project's reference Time server) that gives the two search agents today's date, for the release filters of their searches, and the fitness scenarios ConfigMap.

The chart ships no Model objects. The coordinator and the curator declare `reasoning` and lean to the largest chat model in the cluster's model catalog; the search agents declare `tool-calling` and land on a medium one. One chat model with tool-calling is enough to run it.

## Install

Prerequisites are the same as for the other crews (the Kubemoot operator, NATS JetStream, and a chat model with tool-calling in the cluster's model catalog); see the [repository README](../README.md#install). The operator must forward an external MCP server's key (the `registry.authSecretRef` of an MCPServer with an `externalEndpoint`, reported in its `CredentialReady` condition). No database is needed.

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
| `mcpServers.time.image` | `docker.io/mcp/time@sha256:...` | The Time server, pinned by digest; pin a newer digest to update it |
| `mcpServers.time.localTimezone` | `UTC` | The zone the Time server reports when a call names none |
| `nats.url` | `nats://nats.nats.svc.cluster.local:4222` | NATS JetStream for the artifact store |
| `crew.name` | `oguide` | The Crew's name |
| `crew.placementPolicy` | empty | `algorithm`, `learned`, or `shadow`; empty inherits the cluster default |

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
