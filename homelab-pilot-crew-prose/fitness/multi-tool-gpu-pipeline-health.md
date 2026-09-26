# Multi-tool band: correlate GPU telemetry, serving-pod readiness, and scheduling state into one verdict.

Is the GPU inference path healthy end to end: GPU metrics, the model-serving pods, and the scheduler's GPU assignments all consistent?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty

```reflects
Cross-checks live GPU metrics, the readiness of GPU and model-serving pods, and the scheduler's GPU assignments, and reports a single consistency verdict. The verified live state is two GPU worker nodes advertising nvidia.com/gpu to Kubernetes, both Ollama ModelProviders READY, and the model-serving pods Running, so the GPU inference path is serving and the correct verdict is healthy and consistent (may drift; the constant is correlating the signals against the real state). Empty GPU telemetry at sample time means no active inference, not a broken path; concluding not-healthy-end-to-end or that Kubernetes is unaware of the GPUs contradicts reality. No fabricated inconsistencies.
```
