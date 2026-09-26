# Health-scan band, namespace-scoped pod health; honest 'all healthy' when true, no fabrication.

Are all pods healthy in the kube-system namespace? List any that are not Running.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "pod"

```reflects
The kube-system namespace currently runs about 40 pods, all of them Running with none unhealthy, so the correct answer is that all pods are healthy. A correct answer scans every pod in kube-system (roughly 40, not a fraction) and reports them all Running (the count may drift; the constant is reporting the true health of the real pods in the namespace, never inventing a failing pod).
```
