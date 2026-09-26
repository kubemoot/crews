# Judgment band: reason about PodDisruptionBudget semantics vs maintenance, weighing safety, not just listing.

If I wanted to drain a worker node for maintenance, which PodDisruptionBudgets might block it, and is that safe?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- coordinator produces synthesis
- synthesis is non-empty

```reflects
Currently 4 PodDisruptionBudgets exist: keda-admission-webhooks, keda-operator and keda-operator-metrics-apiserver in the keda namespace, and nats in the nats namespace, each with maxUnavailable=1 (1 allowed disruption). The exact set may drift; the constant is to enumerate ALL live PDBs and omit none. A drain is blocked or delayed only when the drained node hosts 2 or more pods governed by the same PDB (so evicting one would breach its budget); a single pod per node does not block. A sound answer lists every PDB, reasons about which could actually block based on pod placement vs the budget, and gives a balanced safety judgment rather than a bare list; if a real eviction would be blocked, kubectl drain --disable-eviction or --force are the escapes (there is no --ignore-pdb flag).
```
