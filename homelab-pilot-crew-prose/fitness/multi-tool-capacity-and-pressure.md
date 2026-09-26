# Multi-tool band: reconcile node-condition flags against live usage metrics across two tool sources.

Across nodes, are we under any resource pressure (memory, disk, or PID), and does node-condition status agree with current usage metrics?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis does NOT CONTAIN "DiskPressure"
- synthesis does NOT CONTAIN "MemoryPressure"

```reflects
Reads node conditions (MemoryPressure, DiskPressure, PIDPressure) and reconciles them against live usage metrics, reporting whether the two sources agree and surfacing any pressure. The verified live state is all 12 nodes Ready with every pressure condition False, so the correct answer is no pressure and conditions agree with healthy usage (may drift; the constant is reconciling conditions against metrics and reporting the real state). The data is sufficient to answer; claiming incomplete data or could-not-determine when the conditions are present is an evasion that contradicts reality. No invented pressure.
```
