# Judgment band: distinguish requests-vs-allocatable overcommit and judge whether it is actually a problem.

Are any nodes over-committed on CPU or memory requests, and should I be worried?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty

```reflects
Live kubectl describe node shows the cluster over-committed on LIMITS but not on requests: worker-node CPU limits run well over allocatable (currently roughly 110-170 percent) and ephemeral-storage limits far exceed allocatable on some nodes, while CPU and memory REQUESTS stay low (each currently roughly 10-50 percent of allocatable). The exact percentages drift; the durable facts are that requests are the scheduler reservation and remain under allocatable, while limits are not reserved and routinely exceed it. A correct answer distinguishes requests from limits, reports that no node is over-committed on requests, notes the limit overcommit is normal and low-risk here (limits only bite under contention and actual usage is modest), and gives a calibrated not-worried judgment. Punting with 'cannot determine due to invalid data' misses directly observable describe-node data.
```
