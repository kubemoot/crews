# Discovery + judgment band, list ResourceQuotas/HPAs and flag any near limits; real ones only, correct 'none near limits'.

List the ResourceQuotas and HorizontalPodAutoscalers across namespaces, and flag any that
are near their limits.

- POST to discussion endpoint returns 200 with conversationId
- SSE stream emits "thread_found" event within 30 seconds
- discussion completes with "done" event within 480 seconds
- at least 1 specialist contributes with signal=agree
- coordinator produces synthesis
- synthesis is non-empty
- synthesis CONTAINS "quota"

```reflects
The cluster currently has exactly one ResourceQuota, flux-system/critical-pods-flux-system (pods 3 of 1000, far from its limit), and ZERO HorizontalPodAutoscalers anywhere. A correct answer reports the single real quota with nothing near its limit and states there are no HPAs (the set may drift; the constant is reporting only the real discovered quotas and HPAs, never inventing any).
```
