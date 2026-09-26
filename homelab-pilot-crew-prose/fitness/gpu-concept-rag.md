# Concept/RAG band, RAG-grounded conceptual accuracy on GPU compute (CUDA vs Tensor cores); coordinator-answerable, specialists correctly stand aside, no fabrication.

Explain the architectural difference between CUDA cores and Tensor cores on NVIDIA GPUs, and
when each is more efficient.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 300 seconds
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "CUDA" AND "Tensor"

```reflects
Explains CUDA cores as general-purpose SIMT parallel ALUs (graphics/general parallel compute) versus Tensor cores as specialized matrix-multiply-accumulate units for mixed-precision deep-learning math, and when each is more efficient (general/scalar work vs dense matrix multiply). Accurate architectural distinction, no fabricated claims.
```
