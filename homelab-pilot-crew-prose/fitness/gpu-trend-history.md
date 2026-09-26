# Time-series band, GPU utilization trend over a window from DCGM history; honest about limited history, no fabricated spikes.

How has GPU utilization on the cluster's GPUs trended over the last hour? Note any spikes or sustained
high-usage periods.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "GPU"

```reflects
No GPU utilization time-series exists in Prometheus for this cluster because no dcgm-exporter is currently deployed to produce DCGM metrics, so there is no last-hour trend, spikes, or sustained-usage data to report. A correct answer reports the absence of history and attributes it to the missing GPU exporter, rather than fabricating a trend or precise spikes. (the exporter state may drift; the constant is reporting that the time-series is genuinely unavailable and naming the real cause.)
```
