# ocrew-crew

O'crew is a Kubemoot crew for the O'Reilly library. Ask it for the best recent material on a topic, a learning path, upcoming live events, or what an author has published, and it searches the O'Reilly catalog through the O'Reilly MCP server, then ranks, compares, and sequences what it found, with a reader link for every item.

The results are O'Reilly catalog metadata: title, authors, publisher, content type, publication date, page count or duration, live event session dates, and a `learning.oreilly.com` reader link. The catalog search returns no text from inside a book, video, or course, so O'crew never quotes, summarizes, or explains the content itself; it sends you to the right item and says so when asked for more. It stores no O'Reilly content.

## Bring your own key

The O'Reilly MCP server is for O'Reilly subscribers and needs the subscriber's own key. This chart ships no key and never takes one as a value. You create a Secret with your key, and the chart names only the Secret:

```bash
kubectl create secret generic oreilly-mcp-auth \
  --from-literal=bearer-token=<your O'Reilly key> \
  -n crew-ocrew
```

The gateway sends the key as `Authorization: Bearer <key>` on every call to the O'Reilly server.

## What it deploys

| Agent | Role | Tools |
|---|---|---|
| ocrew-coordinator | Plans the turn, convenes the agents a question needs, and writes the answer with a link for every item | none |
| library-search | Turns the question into several focused keyword searches with filters (content type, author, publisher, recency) | `search_oreilly_content` |
| events-scout | Finds upcoming live events and live courses on a topic, with every session date | `search_oreilly_content` |
| curator | Ranks, removes older editions, compares by recency, depth, and audience, and builds reading and learning paths | artifact read-ops only |

Also: 11 ADL PromptModules, the Crew, its CrewSchedulingPolicy, an MCPGateway, the O'Reilly MCPServer (an external endpoint, no deployment), the artifact read-ops MCPServer that lets the curator read large search results, and the fitness scenarios ConfigMap.

The chart ships no Model objects. The coordinator and the curator declare `reasoning` and lean to the largest chat model in the cluster's model catalog; the search agents declare `tool-calling` and land on a medium one. One chat model with tool-calling is enough to run it.

## Install

Prerequisites are the same as for the other crews (the Kubemoot operator, NATS JetStream, and a chat model with tool-calling in the cluster's model catalog); see the [repository README](../README.md#install). The operator must forward an external MCP server's key (the `registry.authSecretRef` of an MCPServer with an `externalEndpoint`). No database is needed.

```bash
kubectl create namespace crew-ocrew
kubectl create secret generic oreilly-mcp-auth \
  --from-literal=bearer-token=<your O'Reilly key> -n crew-ocrew
helm upgrade --install ocrew \
  oci://ghcr.io/kubemoot/charts/ocrew-crew \
  --version <version> \
  -n crew-ocrew
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
| `nats.url` | `nats://nats.nats.svc.cluster.local:4222` | NATS JetStream for the artifact store |
| `crew.name` | `ocrew` | The Crew's name |
| `crew.placementPolicy` | empty | `algorithm`, `learned`, or `shadow`; empty inherits the cluster default |

## Example questions

- "What is the best recent O'Reilly material on running LLM agents on Kubernetes? Include books and videos, newest first."
- "Build me a two-week learning path to understand vector databases using O'Reilly material."
- "What upcoming O'Reilly live events are there on agentic AI, and when are they?"
- "What has Neal Ford published recently on O'Reilly?"

## Fitness

`fitness/` holds five scenarios: recent material, a learning path, live events, an author's recent work, and a request to quote a passage, which the crew declines. Their references name no title, so a catalog that changes does not fail them. The chart deploys them as one ConfigMap, `ocrew-fitness`, labeled `kubemoot.ai/crew` and `kubemoot.ai/fitness-kind: scenarios`; nothing runs until someone starts a run. Assemble them into one suite with [`scripts/build-suite.py`](../scripts/build-suite.py):

```bash
python3 scripts/build-suite.py ocrew-crew/fitness \
  --namespace crew-ocrew --crew-ref ocrew --name ocrew-smoke --iterations 1
```

The `REFLECTS` assertions need the [fitness crew](../kubemoot-fitness-crew/README.md).

## Tests

```bash
bash ocrew-crew/tests/test-render.sh
```
