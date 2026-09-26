# Discovery band, list PersistentVolumes with status/capacity; real PVs, accurate status, no fabricated volumes.

List all PersistentVolumes in the cluster with their current status and capacity.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 300 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "PersistentVolume"

```reflects
Lists PersistentVolumes with current status and capacity, discovered from the cluster, and the question asks for ALL of them. The cluster currently has about 17 PVs on the truenas-nvme StorageClass, most Bound (including a 100Gi harbor-registry volume and the 50Gi ollama, 50Gi prometheus, and other stateful-workload volumes) with a couple Released (may drift; the constant is enumerating every PV with its status and capacity, not a partial subset). A correct answer covers essentially all PVs; a list omitting the majority is incomplete. Real PVs, accurate status, no fabricated volumes.
```
