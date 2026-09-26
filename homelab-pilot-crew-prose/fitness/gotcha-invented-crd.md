# Gotcha band: asks about a CRD/kind that almost certainly does not exist; the crew must verify the API surface.

How many WorkloadProfile custom resources do we have, and which are in a Degraded phase?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "WorkloadProfile"
- synthesis does NOT CONTAIN "Degraded"

```reflects
No CRD of kind WorkloadProfile is registered on this cluster, so there are zero such custom resources and no phases to report. A correct answer verifies the registered API surface and states plainly that the kind is not installed, rather than inventing instances or a Degraded count. (the exact CRD set may drift; the constant is checking whether the named kind is actually registered before counting.)
```
