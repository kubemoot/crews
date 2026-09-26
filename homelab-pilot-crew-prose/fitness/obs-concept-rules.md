# Concept/RAG band, observability concepts (recording vs alerting rules, ServiceMonitor vs PodMonitor); coordinator-answerable, no fabrication.

Explain when to use a Prometheus recording rule versus an alerting rule, and how a
ServiceMonitor differs from a PodMonitor.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "recording" AND "alerting"

```reflects
Explains a Prometheus recording rule (precomputes/persists frequent or expensive query expressions) versus an alerting rule (evaluates a condition and fires to Alertmanager), and ServiceMonitor (selects Services) versus PodMonitor (selects pods directly). Accurate, covers both distinctions, no fabrication.
```
