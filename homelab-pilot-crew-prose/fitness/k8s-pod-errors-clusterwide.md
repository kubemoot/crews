# Health-scan band, cluster-wide non-Running/Completed pods with reasons; honest 'all healthy' when true, no fabricated failures.

List any pods across all namespaces that are not in a Running or Completed state, and note
the reason for each.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "pod"

```reflects
Cluster-wide there are currently ZERO pods outside Running or Completed; every pod is healthy, so the correct answer is a direct 'none, all pods are healthy'. A correct answer states this plainly after scanning all namespaces; punting to a raw artifact or do-it-yourself grep/yq instructions instead of giving the 'none' answer fails the question (the set may drift; if a pod is genuinely failing its real reason must be reported, but no failing pods may be invented).
```
