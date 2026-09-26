# Discovery band: inventory and aggregation across two object kinds with a ranking (counts only, never values).

How many ConfigMaps and Secrets exist per namespace, and which namespaces have the most?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "kube-system"
- synthesis matches "[a-z0-9][a-z0-9-]*" at least 15 times

```reflects
Counts ConfigMaps and Secrets per namespace from live discovery and ranks the heaviest. Currently the ConfigMap leaders are observability (about 35), then the two crew-homelab-pilot crew namespaces (about 24 each), then kube-system (about 10); the Secret leaders are flux-system (about 21), then kubemoot (about 19), harbor (about 12) and kube-system (about 11). The exact counts and ordering drift; the constant is a correct per-namespace count and a ranking that surfaces the genuinely heaviest namespaces (observability for ConfigMaps, flux-system for Secrets). Naming a small namespace as the maximum, or omitting observability and flux-system, contradicts the live distribution. Reports only counts, never Secret contents.
```
