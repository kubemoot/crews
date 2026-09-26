# Discovery band, list nodes with roles/capacity/Ready condition; real node identities, no invented nodes.

List the Kubernetes nodes with their roles, CPU and memory capacity, and current Ready
condition.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "node"

```reflects
The cluster currently has 12 nodes, all Ready: 3 control-plane (homelab-k8s-1-cp, -cp-2, -cp-3, each 4 CPU and about 8Gi), 2 gpu-worker nodes (homelab-k8s-1-gpu-worker and -gpu-worker-2, each 8 CPU and about 48Gi), and 7 worker nodes (4 CPU each, memory about 16-24Gi). A correct answer lists every node with its role, CPU and memory capacity, and Ready status; reporting only a couple of nodes or omitting capacity is a severe under-report (the count and capacities may drift; the constant is enumerating all real discovered nodes with their roles and capacity, never inventing nodes).
```
