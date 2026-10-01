# Selectivity band, GPU model from node labels and VRAM in use from DCGM; say plainly what cannot be determined, never estimate.

What GPU model is installed on each hypervisor host, and how much VRAM is currently in use on each? If any part of this cannot be determined from the available tools, say so explicitly rather than estimating.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "VRAM"

```reflects
Both sub-parts are answerable from the available tools. GPU model: node labels nvidia.com/gpu.product expose an RTX 5090 (about 32 GB) on one gpu-worker and an RTX 4090 (about 24 GB) on the other. VRAM in use: the dcgm-exporter in the observability namespace exports DCGM_FI_DEV_FB_USED and DCGM_FI_DEV_FB_FREE (MiB) for each GPU, and Prometheus scrapes them. A correct answer names each GPU model per host or node and reports its current VRAM in use with units, taken from the DCGM metrics; anything it still cannot determine it states plainly instead of estimating. The VRAM values change with load and are not scored. Claiming the models cannot be determined, claiming VRAM in use is not measurable or that no exporter is deployed, or fabricating VRAM numbers misses. (GPU models and exporter placement may drift; the constant is model from node labels and VRAM from DCGM.)
```
