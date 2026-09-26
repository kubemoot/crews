# Cross-domain discovery band, running Proxmox VMs with node assignment and resource usage; real VMs, no fabrication.

List the running VMs on the Proxmox cluster with their assigned nodes and current resource
usage.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 300 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "VM"

```reflects
Lists the VMs on the Proxmox cluster with node assignment, discovered live from the Proxmox API. The real inventory centers on the Kubernetes node VMs (currently 12 Talos VMs named homelab-k8s-1-* and homelab-k8s-2-*) and may also include Windows GPU-passthrough or infrastructure VMs (may drift; the constant is real Talos k8s VMs discovered from the API, not generic distro VMs). Real discovered VM names score well; inventing placeholders such as Ubuntu-2204-VM or CentOS-Stream-9-VM on proxmox-node1/2, or uniform round-number resource usage, fabricates and misses.
```
