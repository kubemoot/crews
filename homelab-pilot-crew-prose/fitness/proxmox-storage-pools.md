# Discovery band: a new Proxmox surface, storage-pool inventory distinct from node and VM lists.

List the Proxmox storage pools with their type, total capacity, and current usage.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis matches "[A-Za-z0-9_-]+" at least 2 times

```reflects
Enumerates the Proxmox storage pools with their type, discovered via the Proxmox API. Pools currently include local, local-lvm, and passthrough or NFS pools such as windows-storage (disabled), rig1-storage, and storage-nfs (may drift; the constant is real pool names and types from the API). Per-pool capacity and usage are NOT exposed by that listing tool, so honestly stating the metric gap and naming pvesm status or the storage status API as the fix is correct; fabricating capacities or usage figures misses.
```
