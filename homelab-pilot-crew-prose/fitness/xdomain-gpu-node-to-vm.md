# Cross-domain band, match a Kubernetes node to its backing hypervisor VM by identity across two tool domains (multi-hop correlation).

Our Kubernetes GPU worker nodes run as virtual machines on the Proxmox hypervisor. For each GPU worker node, identify which Proxmox host it runs on and its VM id, and report the vCPUs Proxmox allocates to it.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 600 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty

```reflects
There are currently two GPU worker nodes (homelab-k8s-1-gpu-worker and homelab-k8s-1-gpu-worker-2), each backed by its own Proxmox VM via GPU passthrough, and each currently has 8 vCPUs. A correct answer discovers both GPU nodes via Kubernetes, correlates each to its backing Proxmox VM (host, VM id, vCPUs) by matching identity across the two tool domains, and reports both nodes rather than one. Reporting only a single node, handing the second back to the user, or stating a vCPU count that contradicts reality (such as 1 vCPU when each node has 8) does not match. (node names and vCPU counts may drift; the constant is the cross-domain identity correlation covering every GPU node.)
```
