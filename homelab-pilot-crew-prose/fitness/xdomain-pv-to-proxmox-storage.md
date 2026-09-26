# Cross-domain band: a multi-hop PV to node/CSI to hypervisor-storage reconciliation; flag any unprovable hop.

Trace where a PersistentVolume's data physically lives, from the PV down to the Proxmox storage backing it, and report the backing pool.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty

```reflects
Every PersistentVolume currently binds to the single default StorageClass truenas-nvme, provisioned by democratic-csi (driver org.democratic-csi.nvmeof) over NVMe-oF and physically backed by a TrueNAS ZFS pool. A correct answer traces a PV through its StorageClass and CSI driver down to that TrueNAS-backed storage, naming truenas-nvme and democratic-csi, and explicitly flags the TrueNAS-internal hop the in-cluster tools cannot fully establish rather than inventing pool internals. (the StorageClass and driver may drift; the constant is the PV-to-physical-storage reconciliation method and honesty about the gap.)
```
