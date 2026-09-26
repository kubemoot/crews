# Discovery band: DaemonSet desired-vs-ready-vs-available reasoning across nodes.

List the DaemonSets and confirm each is scheduled on all the nodes it should cover.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "cilium"
- synthesis matches "[a-z0-9][a-z0-9-]*" at least 5 times

```reflects
Enumerates DaemonSets and compares desired vs ready and available across nodes, noting any with unscheduled or unavailable pods. The real DaemonSets are the Cilium CNI (cilium, cilium-envoy), the GPU-operator node set (nvidia device-plugin, feature-discovery, operator-validator), the democratic-csi node plugin, and the observability node agents (prometheus node-exporter, otel-collector). The CNI is Cilium: there is NO calico, NO kube-proxy DaemonSet (Cilium replaces kube-proxy), NO flannel or weave, and NO fluentd or fluent-bit (node logging runs through the otel-collector). A correct answer reports only the real DaemonSets and assesses coverage correctly; inventing calico, kube-proxy, fluentd, or any non-existent DaemonSet is a fabrication to mark down. The exact set may drift; the constants are the Cilium CNI and the absence of calico/kube-proxy/fluentd.
```
