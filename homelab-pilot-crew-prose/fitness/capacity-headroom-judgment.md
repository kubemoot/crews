# Judgment band, capacity reasoning plus the Kubernetes rule that control-plane nodes are not a general scheduling target.

If I needed to schedule a workload requiring a moderate amount of RAM and CPU, which worker nodes currently have the headroom, and is the cluster's control plane an appropriate place for it? Explain the trade-off.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "control"
- synthesis CONTAINS "worker"

```reflects
The cluster node capacity IS determinable from live state, so naming which workers have headroom is answerable. A correct answer inspects node allocatable and usage, identifies worker nodes with available RAM and CPU, and argues the control-plane nodes are not an appropriate target for general workloads. Currently 12 Ready nodes exist: 3 control-plane (about 8Gi/4cpu each), 2 gpu-worker (about 49Gi/8cpu), and 7 general workers (five at about 16Gi/4cpu, two at about 24Gi/4cpu); claiming the node data is corrupted or unavailable is wrong. A correct answer names some of the real worker nodes with headroom and excludes the control plane with reasoning. (The exact nodes and free amounts drift; the constant is inspecting live node capacity and applying the control-plane exclusion.)
```
