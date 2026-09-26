# Observability band: a correct rate() over a window with a calibrated 'elevated or not' judgment, no invented number.

Using PromQL, what is the cluster's HTTP 5xx error rate over the last hour, and is it elevated?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "5xx"

```reflects
Builds a correct PromQL rate query for 5xx responses over the window and gives a calibrated elevated-or-not judgment. The homelab has no guaranteed app-level HTTP status instrumentation (a http_requests_total series with a status label), so if that series is absent the correct answer states the instrumentation gap and how to close it (add a ServiceMonitor or expose status-labeled request counters) rather than inventing a number; if the series exists, report a plausible magnitude (may drift; the constant is a correct method plus an honest magnitude or an honest gap). 'Error rate is negligible or zero' is correct when true; no fabricated number.
```
