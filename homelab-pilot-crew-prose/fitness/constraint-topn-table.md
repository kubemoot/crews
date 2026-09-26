# Constraint band: honor a count cap, ranking order, exact column shape, and 'nothing else'.

Give me exactly the top 5 namespaces by pod count, as a two-column table of namespace and count, highest first, and nothing else.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis does NOT CONTAIN "could not be retrieved"

```reflects
The cluster currently has roughly two dozen namespaces that contain pods, so a top-5-by-pod-count ranking is fully answerable and 'could not be retrieved' is wrong. A correct answer returns exactly five namespaces ranked by pod count descending in a two-column namespace and count table with no extra prose, discovered live. Honoring the count cap, sort order, table format, and the no-extra-output constraint is the point; the specific namespaces and counts are not scored. (The distribution drifts; if genuinely fewer than five namespaces had pods, reporting all of them honestly would be correct.)
```
