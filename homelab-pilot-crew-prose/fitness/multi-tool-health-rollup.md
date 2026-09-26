# Multi-tool band, synthesize four independent signals across tools and report healthy without inventing problems.

Give me a one-paragraph health rollup of the cluster: node readiness, any not-Ready pods, Helm releases not in a deployed state, and whether the GPU inference backends are serving. Flag anything abnormal; if everything is healthy, say so plainly.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 600 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "Ready"

```reflects
Synthesizes node readiness, pod health, Helm release state, and GPU serving status from live discovery into one rollup, flagging genuine abnormalities and plainly stating health when all is well. The verified live state is all 12 nodes Ready, workloads healthy, every Helm release deployed, and both Ollama ModelProviders READY and serving, so the correct rollup is all healthy across the four signals (may drift; the constant is combining all four and not inventing problems). Covering only a couple of the 12 nodes, or calling the GPU backends abnormal off a monitoring-query error while they are serving, contradicts reality. Do not fabricate problems.
```
