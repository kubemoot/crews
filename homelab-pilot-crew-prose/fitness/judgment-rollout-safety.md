# Judgment band: weigh current load, readiness, and replica counts to judge timing, not reflexively say yes.

Is it safe to restart the busiest namespace's deployments right now?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty

```reflects
Deployment readiness is directly observable via kubectl, and all deployments in the cluster currently report fully ready (READY matches desired across all namespaces). The specific busiest namespace and per-deployment replica counts may drift; the constant is that readiness and replica/surge posture ARE knowable from live state. A correct answer discovers the busiest namespace and its deployments' readiness and replica/surge capacity, then gives a reasoned timing judgment (safe to restart if healthy replicas and surge headroom exist, caution if single-replica or already degraded) rather than a reflexive yes or no. Refusing with 'not possible to determine safety' or resting on a near-empty metrics result ignores the available deployment-readiness data.
```
