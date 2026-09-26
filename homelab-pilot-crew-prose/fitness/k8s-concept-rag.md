# Concept/RAG band, conceptual accuracy on Deployment vs StatefulSet incl. storage/networking implications; coordinator-answerable, no fabrication.

Explain the differences between a Kubernetes Deployment and a StatefulSet. Include when to
use each and the implications for storage and networking.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 300 seconds
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "Deployment" AND "StatefulSet"

```reflects
Explains Deployment (stateless, interchangeable pods, rolling updates, shared/ephemeral storage) versus StatefulSet (stable network identity via headless service + ordinal pods, ordered lifecycle, per-pod persistent storage via volumeClaimTemplates), when to use each, and the storage/networking implications. Accurate, no fabrication.
```
