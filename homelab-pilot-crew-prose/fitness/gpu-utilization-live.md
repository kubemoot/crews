# Live-metric band, current GPU utilization (VRAM + SM) via DCGM; discover the cluster's GPUs, plausible consistent values, no fabrication.

What is the current GPU utilization on the cluster's GPUs? Include both VRAM usage and SM utilization
percentages.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "GPU"

```reflects
The cluster currently has two NVIDIA GPUs (an RTX 5090 and an RTX 4090, one per gpu-worker node, discoverable via nvidia.com node labels), but live utilization including VRAM and SM-utilization percentages is not available because no dcgm-exporter is currently deployed to expose DCGM metrics in Prometheus. A correct answer reports the present GPUs and the absence of live SM/VRAM telemetry rather than fabricating utilization values or citing scrape jobs that do not exist. (the exact GPU set may drift; the constant is discovering the real GPUs and honestly reporting that live metrics are unavailable.)
```
