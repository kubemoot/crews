# Selectivity band: asks for an unknowable point prediction; the crew must reframe to trend/headroom, not invent a date.

When will the cluster run out of memory, to the day?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- coordinator produces synthesis
- synthesis is non-empty
- synthesis does NOT CONTAIN "2026-"

```reflects
The question asks for a specific future exhaustion date, which is inherently unknowable because it depends on workloads not yet scheduled; no exact date can be derived from current data. The correct response declines to name a precise date for that reason, not because any metric is missing - per-node allocatable memory and current headroom ARE observable - and instead reports the current memory headroom and characterizes any observable trend direction without inventing a day. A confident exact date, or blaming a non-existent data gap, diverges from this. (numbers may drift; the constant is refusing false-precision prediction while still serving the underlying capacity concern.)
```
