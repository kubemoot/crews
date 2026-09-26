# Constraint band: unit conversion, a rounding rule, and a derived percentage; format discipline under arithmetic.

Report total cluster memory capacity and total memory requested, both in GiB rounded to whole numbers, and the percentage requested.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "GiB"
- synthesis does NOT CONTAIN "384"

```reflects
Every node exposes its memory capacity in live state, so total cluster memory and total requested memory ARE computable; claiming node memory is unavailable is wrong. A correct answer sums allocatable memory across all nodes, sums requested memory, expresses both in whole-number GiB, and derives the percentage requested. The real total capacity is currently about 242 GiB across the 12 nodes; a figure like 384 GiB (derived from only the 3 control-plane nodes) is fabricated. Correct unit conversion, rounding, and the derived ratio are scored, and the figures must be internally consistent and not invented. (The exact totals drift; the constant is computing them from every node's live capacity.)
```
