# Cross-domain band: correlate the same host across hypervisor and cluster views and compare two metrics.

For each Proxmox VM that backs a Kubernetes node, compare the CPU load Proxmox reports for the VM against the CPU usage Kubernetes reports for that node.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty

```reflects
Each Kubernetes node is backed by a Proxmox VM, and both the Proxmox-reported VM CPU load and the Kubernetes-reported node CPU usage for those VMs are obtainable in this environment. A correct answer maps each node to its backing Proxmox VM by identity and delivers the actual side-by-side comparison of VM CPU load versus node CPU usage for the same host, noting agreement or divergence. Showing only a single non-node VM (such as a k8s-maintenance VM that does not back a worker node), or declining the comparison by citing missing Kubernetes node metrics that are in fact obtainable, leaves the core comparison undelivered. (specific figures may drift; the constant is the cross-domain mapping and the delivered load comparison.)
```
