# Observability band: query target liveness (the up metric) and report down targets honestly.

Are all of Prometheus's scrape targets currently up, and if any are down, which jobs do they belong to?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis does NOT CONTAIN "all targets are down"
- synthesis CONTAINS "Prometheus"

```reflects
Inspects Prometheus scrape-target health (the up metric or the targets endpoint) and reports whether all targets are up, naming the job for any that are down. The verified live state is Prometheus running (the prometheus statefulset is 1/1 in the observability namespace), so its scrape targets are presumably mostly up and a substantive answer is expected (may drift; the constant is querying real target health). A correct answer reports the target state; if the targets query genuinely fails an honest statement of the failure is acceptable, but a two-sentence content-free non-answer is thin. 'All targets up' is correct when true; no fabricated down targets.
```
