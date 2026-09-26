# Live-metric band, per-GPU utilization/VRAM/temperature across every GPU the cluster has; discovery covers all GPUs, no fabrication.

What is the current GPU utilization, VRAM usage, and temperature on each GPU in the cluster?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "GPU"

```reflects
The cluster currently has two NVIDIA GPUs, an RTX 5090 (about 32 GB VRAM) and an RTX 4090 (about 24 GB VRAM), each on a dedicated gpu-worker node and discoverable via nvidia.com node labels. Live per-GPU utilization, VRAM usage, and temperature are not available because no dcgm-exporter is currently deployed (the gpu-operator stack lives in the gpu-operator namespace). A correct answer discovers the real GPUs and reports that live telemetry is unavailable rather than fabricating utilization, VRAM, or temperature values. (the exact GPU models and node names may drift; the constant is discovering the present GPUs and reporting absent metrics honestly.)
```
