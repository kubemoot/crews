# Concept/RAG band: observability concept depth (label explosion, TSDB cost, mitigation), no fabrication.

Explain metric cardinality in Prometheus, why high cardinality is a problem, and how to reduce it.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "cardinality"

```reflects
Explains cardinality as the count of unique label combinations, why high cardinality strains Prometheus memory and the TSDB, and concrete mitigations (drop or relabel high-cardinality labels, avoid unbounded label values, use recording rules). Accurate, no fabrication; coordinator-answerable.
```
