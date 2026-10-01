# Time-series band, GPU utilization trend over a window from DCGM history; no fabricated trend or spikes.

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
A dcgm-exporter DaemonSet in the observability namespace has been scraped continuously by Prometheus, so a DCGM_FI_DEV_GPU_UTIL time-series with regular samples exists for both GPUs (an RTX 5090 and an RTX 4090) over the last hour. A correct answer runs a range query over that hour and summarizes the trend per GPU (for example average and peak utilization, when any spike happened, and whether high usage was sustained), with every figure taken from the returned series. The trend itself depends on the crew's own load at the time and is not scored; what is scored is that a range query was used, each GPU is covered, and no trend, spike, or value is invented. Stating that no GPU history exists or that no exporter is deployed contradicts the live state and misses. (GPU models and exporter placement may drift; the constant is a per-GPU trend read from the DCGM time-series.)
```
