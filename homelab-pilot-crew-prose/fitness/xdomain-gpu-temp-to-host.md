# Cross-domain band: join DCGM GPU telemetry to the hypervisor host that owns the GPU.

Correlate each GPU's current temperature with the Proxmox host it is passed through to, so I know which physical host is running hot.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty

```reflects
The GPUs are passed through to physical Proxmox hosts (rig0, rig1, rig2), and per-GPU temperature comes from DCGM. A correct answer joins live per-GPU temperature to the Proxmox host each GPU is passed through to and reports temperature by physical host. DCGM per-GPU temperature can be unavailable in a given run; when it is, honestly stating that the temperatures could not be retrieved - rather than fabricating host-and-temperature pairs - is correct, even though GPU temperature is a standard metric and an empty result reflects an infrastructure gap rather than a true impossibility. (host topology may drift; the constant is the GPU-to-host correlation method plus honesty about a real data gap.)
```
