# Discovery band, discover which DCGM metrics are actually exposed to Prometheus and verify scrape targets are up; discovery + liveness, no invented metrics.

What DCGM GPU metrics are available from Prometheus, and are the GPU exporter scrape targets
currently up?

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "DCGM"
- synthesis matches "DCGM_FI_[A-Z_]+" at least 3 times

```reflects
A dcgm-exporter DaemonSet in the observability namespace runs one pod on each GPU node, and Prometheus scrapes each pod as a target of the dcgm-exporter job; both targets are up. About two dozen DCGM metric names are exposed, all prefixed DCGM_FI_, including DCGM_FI_DEV_GPU_UTIL, DCGM_FI_DEV_FB_USED, DCGM_FI_DEV_FB_FREE, DCGM_FI_DEV_GPU_TEMP, DCGM_FI_DEV_MEMORY_TEMP, DCGM_FI_DEV_POWER_USAGE, DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION, DCGM_FI_DEV_SM_CLOCK, DCGM_FI_DEV_MEM_CLOCK and the DCGM_FI_PROF_ profiling family. A correct answer lists metric names it actually found in Prometheus and reports the scrape-target health it actually observed. The exact metric set and count are not scored; listing a metric name Prometheus does not expose, inventing a target, or claiming that no DCGM metrics or no exporter exist misses. (exporter placement and the metric set may drift; the constant is reporting the exposed DCGM metric names and the observed target health, with nothing invented.)
```
