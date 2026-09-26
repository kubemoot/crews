# Concept/RAG band, virtualization concepts (Proxmox LXC vs KVM, when to choose each); coordinator-answerable, no fabrication.

What are the key differences between Proxmox LXC containers and KVM virtual machines, and
when would you choose each?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 300 seconds
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "LXC" AND "KVM"

```reflects
Explains Proxmox LXC containers (OS-level, shared host kernel, lightweight, high density, Linux guests, lower isolation) versus KVM virtual machines (full virtualization, own kernel, any OS, stronger isolation, snapshots/live-migration/PCIe passthrough, more overhead), and when to choose each. Accurate, no fabrication.
```
