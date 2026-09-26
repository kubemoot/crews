# Concept/RAG band: virtualization-HA concept accuracy (HA manager, fencing, quorum/corosync), no fabrication.

Explain how Proxmox HA and fencing work, and what a quorum is for in a Proxmox cluster.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "quorum"

```reflects
Explains the Proxmox HA stack: the built-in ha-manager (pve-ha-crm and pve-ha-lrm, Proxmox's own, not Pacemaker), fencing of a failed node, and the role of Corosync-based quorum in preventing split-brain, plus when HA is appropriate. Accurate conceptual explanation, coordinator-answerable without live cluster data; naming Pacemaker as the Proxmox HA manager is inaccurate.
```
