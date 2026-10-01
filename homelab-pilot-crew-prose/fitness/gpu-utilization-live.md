# Live-metric band, current GPU utilization and VRAM via DCGM (no SM-active metric is exported); every GPU covered, values from DCGM, no fabrication.

What is the current GPU utilization on the cluster's GPUs? Include both VRAM usage and SM utilization
percentages.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "GPU"
- synthesis matches "[0-9]+(\.[0-9]+)? ?%" at least 2 times

```reflects
The cluster has two NVIDIA GPUs, an RTX 5090 and an RTX 4090, one per gpu-worker node. A dcgm-exporter DaemonSet in the observability namespace exposes their live DCGM metrics in Prometheus: DCGM_FI_DEV_GPU_UTIL (percent) is the utilization figure, DCGM_FI_DEV_FB_USED and DCGM_FI_DEV_FB_FREE (MiB) give VRAM in use and free, and DCGM_FI_PROF_GR_ENGINE_ACTIVE (a 0 to 1 ratio) is the closest engine-activity figure; no SM-active or SM-occupancy metric is exported. A correct answer reads these metrics and reports, for each GPU, its utilization percentage and VRAM used against total, with units, and either derives SM activity from the exposed metrics with that stated or says a dedicated SM-active metric is not exported. The values change from minute to minute and are not scored; what is scored is that every value comes from the DCGM data and every GPU present is covered. Stating that live GPU telemetry is unavailable or that no exporter is deployed contradicts the live state and misses; fabricated values, or a scrape job or metric that does not exist, miss. (GPU models and exporter placement may drift; the constant is reading live DCGM metrics per GPU and reporting only what they show.)
```
