# Cross-domain discovery band, Proxmox nodes + storage-pool capacity/usage via the Proxmox API; real nodes/pools, accurate health.

List the Proxmox nodes with their health status, and the capacity and usage of each ZFS or
storage pool.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "node"

```reflects
Reports the Proxmox node(s) with health/online status discovered from the Proxmox API; the cluster runs the Proxmox hypervisor host(s) that back the Talos VMs (may drift; the constant is real node names from the API). Per-storage-pool capacity and usage are NOT exposed by the available Proxmox listing tool, so an honest statement that capacity/usage is unavailable (naming pvesm status or the storage status API as the method) is correct; fabricating pool sizes or usage percentages misses.
```
