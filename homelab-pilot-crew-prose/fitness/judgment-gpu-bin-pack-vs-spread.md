# Judgment band: GPU scheduling judgment (utilization, VRAM headroom, contention) over live state.

I have one more GPU job to place. Should I bin-pack it onto the busiest GPU or spread it to an idle one? Explain the trade-off.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty

```reflects
The cluster currently has exactly 2 GPU worker nodes (gpu-worker and gpu-worker-2), 1 GPU each, both backing Ollama ModelProviders (the exact names and count may drift; the constant is a small, enumerable GPU pool). No DCGM exporter is deployed, so per-GPU live utilization and VRAM are not scrapeable from cluster metrics. A sound answer states this observability gap honestly, notes the trivial 2-GPU topology that bounds the choice, and reasons the bin-pack vs spread trade-off (consolidation and power efficiency vs contention, thermal load and tail latency), landing on a defensible default such as spread. The trade-off reasoning grounded in the real topology is scored, not a fixed recommendation; claiming live per-GPU utilization without DCGM is fabrication.
```
