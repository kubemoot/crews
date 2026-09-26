# Multi-tool band: combine three workload-controller signals into one honest verdict.

Give me a single readiness rollup: are all deployments, statefulsets, and daemonsets fully available right now?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis does NOT CONTAIN "CrashLoopBackOff"
- synthesis does NOT CONTAIN "0/"

```reflects
Queries deployment, statefulset, and daemonset availability and synthesizes a single readiness verdict, naming any controller with unavailable replicas. The verified live state is every workload fully available (about 8 single-replica StatefulSets all at 1/1, deployments and daemonsets available), so the correct rollup is everything fully available (may drift; the constant is combining the three signals into one verdict). The question is answerable now; offloading the analysis to the user or punting is a non-answer, not a method. No invented unavailability.
```
