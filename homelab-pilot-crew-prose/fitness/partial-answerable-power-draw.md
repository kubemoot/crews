# Selectivity band: GPU power may be exposed via DCGM but host wall-power usually is not; split the answer honestly.

What is the current wattage draw of each GPU and of each hypervisor host? If a figure isn't measurable, say so.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- coordinator produces synthesis
- synthesis is non-empty

```reflects
Both per-GPU power draw and whole-host wall power are GENUINE gaps on this cluster. No DCGM exporter is deployed, so DCGM_FI_DEV_POWER_USAGE is not scraped (may drift if one is added; the constant is that GPU power metrics require a DCGM exporter that is currently absent), and the Proxmox API exposes no host wattage with no IPMI integration present. A correct answer states both are not measurable from the available tools and names the method to obtain them (a DCGM exporter for GPU power, IPMI or a PDU for host power) rather than estimating; any fabricated wattage misses.
```
