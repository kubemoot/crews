# Selectivity band: GPU power is exposed via DCGM but host wall-power is not; split the answer.

What is the current wattage draw of each GPU and of each hypervisor host? If a figure isn't measurable, say so.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- coordinator produces synthesis
- synthesis is non-empty
- synthesis matches "[0-9]+(\.[0-9]+)? ?(W|watts)\b" at least 2 times

```reflects
The two parts of the question have different answers. Per-GPU power draw IS measurable: the dcgm-exporter in the observability namespace exports DCGM_FI_DEV_POWER_USAGE in watts for each GPU (an RTX 5090 and an RTX 4090), and Prometheus scrapes it. A correct answer reports the current draw of each GPU in watts from that metric. Whole-host wall power for the Proxmox hypervisor hosts is a GENUINE gap: the Proxmox API exposes no host wattage and no IPMI or PDU integration is scraped, so a correct answer states that host wattage is not measurable from the available tools and names how to obtain it (IPMI, a metered PDU, or an inline power meter) rather than estimating it, and never presents GPU draw as host draw. GPU wattage changes with load and the values are not scored; reading them from DCGM is. Any fabricated wattage, a claim that GPU power is not measurable, or a claim that no DCGM exporter is deployed misses. (GPU models and exporter placement may drift; the constant is GPU power read from DCGM and host power reported as an unmeasured gap.)
```
