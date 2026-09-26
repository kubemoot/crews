# Triage band, scan Warning-level events over a window and summarize the most concerning; honest 'none concerning', no fabricated events.

Are there any Warning-level Kubernetes events in the last hour? Summarize the most
concerning ones.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis does NOT CONTAIN "OOMKilled"
- synthesis does NOT CONTAIN "DiskPressure"

```reflects
Checks cluster-wide Warning-level Kubernetes events over the window and summarizes the most concerning. A recurring Warning currently exists: flux-system imagerepository/homelab-pilot reporting 'ReadOperationFailed scan failed ... NOT_FOUND repository homelab/pilot not found', which fires persistently. The specific warning may drift, but the durable point is that the events query returns real Warnings and the correct method surfaces them. A sound answer reports the actual recurring warning (or whatever genuine Warnings are present) with a coherent summary; a confident all-clear of no Warning events built on an empty or NO_DATA result misses the live recurring warning. No fabricated events.
```
