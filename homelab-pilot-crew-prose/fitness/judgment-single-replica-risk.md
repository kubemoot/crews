# Judgment band: identify single points of failure and give a sound remediation judgment.

Which of our workloads would cause an outage if their single node went away, and what would you do about it?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty

```reflects
Most workloads run as a single replica; real single-replica single-points-of-failure currently include cert-manager (cert-manager, cert-manager-cainjector and cert-manager-webhook are each 1 replica), cloudflared (the sole ingress tunnel, 1 replica) and arc-controller-gha-rs-controller (1 replica), plus single-instance StatefulSets such as nats. The exact list drifts; the constant is to discover replica counts from live state and flag the ones whose loss causes a real outage. A sound answer identifies workloads pinned to a single replica or node, judges blast radius per workload, and gives appropriate remediation (raise replicas, pod anti-affinity to spread across nodes, PodDisruptionBudgets) rather than a generic blanket fix. The single-point-of-failure identification grounded in live replica data and the per-workload remediation reasoning are scored.
```
