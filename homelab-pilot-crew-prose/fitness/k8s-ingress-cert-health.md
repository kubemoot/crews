# Discovery band: Ingress and certificate surface with an expiry judgment; honest 'all valid'.

List the Ingress resources and TLS certificates, and flag any cert that is expired or close to expiry.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "harbor"
- synthesis does NOT CONTAIN "expired"

```reflects
The cluster exposes no Ingress resources (it uses the Gateway API), and cert-manager Certificates ARE listable: it currently holds 2, default/harbor-internal-tls and kubemoot/kubemoot-operator-webhook, both Ready with valid non-expired certificates. A correct answer discovers and names the real certs and reports them all valid; 'could not retrieve any' or naming nothing is wrong because the data is available (the set may drift; the constant is reporting the real discovered certs and their true validity, never inventing certs or dates).
```
