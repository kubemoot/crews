# Concept/RAG band: conceptual accuracy on scheduling vs enforcement and the CPU-throttle vs memory-OOM distinction.

Explain the difference between CPU/memory requests and limits in Kubernetes, including what happens when each is exceeded.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "limit"

```reflects
Explains requests (used for scheduling and a guaranteed share) vs limits (enforced ceilings), and correctly distinguishes the over-limit behavior: CPU is throttled while memory over-limit triggers an OOMKill. Accurate, no fabrication; coordinator-answerable without needing live cluster data.
```
