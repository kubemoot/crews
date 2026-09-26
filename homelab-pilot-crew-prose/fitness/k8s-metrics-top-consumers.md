# Live-metric band, rank top pods by memory via the metrics API; real pod names, correct ranking, no fabrication.

What are the top 5 pods by memory consumption across the cluster right now?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "memory"

```reflects
Cluster-wide, the genuine top memory consumers are the GPU model-serving pods (ollama in ollama-rig0 and ollama-rig1, in the multi-GiB range with ollama-rig0 the largest), followed by sonarqube, the kube-apiserver replicas, and the prometheus pod, all above roughly 1.5Gi. A correct cluster-wide top-N surfaces these GiB-scale inference and system pods by real name; a list that tops out at a few hundred Mi has only scanned the crew namespaces and missed the real heaviest pods (exact numbers drift with load; the constant is that the true heavy hitters are GiB-scale model, database, or monitoring pods reported by real name, never fabricated).
```
