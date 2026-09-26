# PromQL band, compute kube-apiserver request rate via PromQL over a window; correct query method, plausible magnitude, no fabricated figure.

What is the current request rate (requests per second) for kube-apiserver across all
instances? Include the last 5 minutes average.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 300 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "rate"

```reflects
The kube-apiserver request rate IS answerable on this cluster: Prometheus scrapes apiserver_request_total (currently via the kube-prometheus-stack-apiserver ServiceMonitor in the observability namespace; may drift, the constant is that apiserver request metrics are scraped). A correct answer computes the rate with PromQL such as rate(apiserver_request_total[5m]) summed across instances and reports a plausible requests/second magnitude; declining, or giving up on a wrong metric name such as kube_apiserver_request_total, misses available data.
```
