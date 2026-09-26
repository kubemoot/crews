# Behavior band, a non-question greeting; respond warmly and offer help, reach consensus without fabricating cluster claims or refusing.

Hello world

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 300 seconds
- coordinator produces synthesis
- synthesis is non-empty
- at least 0 specialist contributes with signal=agree

```reflects
A brief, friendly greeting that offers to help with the homelab/cluster. Concise, not over-engineered, makes no fabricated cluster claims, does not refuse.
```
