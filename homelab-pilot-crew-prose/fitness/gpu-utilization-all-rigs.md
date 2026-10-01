# Live-metric band, per-GPU utilization/VRAM/temperature across every GPU the cluster has; discovery covers all GPUs, no fabrication.

What is the current GPU utilization, VRAM usage, and temperature on each GPU in the cluster?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "GPU"
- synthesis matches "[0-9]+(\.[0-9]+)? ?%" at least 2 times

```reflects
The cluster has two NVIDIA GPUs, each on its own gpu-worker node: an RTX 5090 (about 32 GB VRAM) and an RTX 4090 (about 24 GB VRAM). A dcgm-exporter DaemonSet in the observability namespace runs one pod per GPU node, and Prometheus scrapes live DCGM series for both GPUs: DCGM_FI_DEV_GPU_UTIL (percent), DCGM_FI_DEV_FB_USED and DCGM_FI_DEV_FB_FREE (MiB), and DCGM_FI_DEV_GPU_TEMP (degrees C). A correct answer reads these metrics and reports, for each GPU, its utilization, VRAM used against total, and temperature, with units, attributed to the right GPU. The values change from minute to minute and are not scored; what is scored is that every reported value comes from the DCGM data, that every GPU present is covered, and that no GPU or value is invented. Stating that live GPU telemetry is unavailable or that no exporter is deployed contradicts the live state and misses; if a run could not retrieve the data, saying so beats inventing numbers but does not answer the question. (GPU models, node names and exporter placement may drift; the constant is reading live DCGM metrics per GPU and reporting only what they show.)
```
