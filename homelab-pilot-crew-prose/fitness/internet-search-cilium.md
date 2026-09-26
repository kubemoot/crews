# Internet-research band, researcher fetches the current Cilium release line + real features from the web; coordinator synthesizes, no fabrication.

What is the latest stable release version of the Cilium CNI, and what are its headline
features?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "Cilium"

```reflects
Cilium is the eBPF-based CNI on this cluster, and a correct answer identifies it as such and lists real headline features (eBPF dataplane, Hubble observability, network policies including L7, sidecarless service mesh, Gateway API, BGP, egress gateway, transparent encryption, ClusterMesh). It reports the current stable release line obtained by actually searching the web at answer time, not a version recalled from training data. (the latest version number drifts continually; the constant is fetching the current release live and not fabricating features.)
```
