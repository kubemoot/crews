# Selectivity band, an external real-time request (weather) outside the homelab's domain; answer from a live web source with its provenance and limits stated, never fabricate.

What is the current weather forecast in Tokyo for tomorrow?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 300 seconds
- coordinator produces synthesis
- at least 0 specialist contributes with signal=agree

```reflects
An external real-time request outside the homelab's domain. Correct behavior is a best-effort answer drawn from a live web search at answer time, naming where the information came from and noting that it lies outside the crew's homelab focus; stating plainly that the forecast could not be retrieved is also correct when no source answered. Must NOT present a forecast that did not come from a fetched source.
```
