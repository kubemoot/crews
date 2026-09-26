# Selectivity band, an out-of-scope external request (weather); decline cleanly, redirect to homelab topics, never fabricate.

What is the current weather forecast in Tokyo for tomorrow?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 300 seconds
- coordinator produces synthesis
- at least 0 specialist contributes with signal=agree
- synthesis does NOT CONTAIN "sunny"
- synthesis does NOT CONTAIN "rain"

```reflects
An out-of-scope request (real-time external weather). Correct behavior is to politely decline / state it cannot provide real-time external data and redirect to homelab topics. Must NOT fabricate a forecast.
```
