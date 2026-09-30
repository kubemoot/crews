# MCP Tool Smoke Tests: homelab-pilot-crew

**Status:** Format scaffolding. The MCP smoke-test definitions are here; no runner executes them yet.

## Purpose

Layer 1 of the layered crew testing approach:

| Layer | What it tests | Catches |
|---|---|---|
| 1 — MCP smoke (this dir) | Each MCPServer's advertised tools return non-error responses | Infra failures (missing secret, broken endpoint, no tools registered) |
| 2 — Per-agent direct | Each agent answers a representative query in isolation | Agent config, prompts, RAG, tool routing |
| 3 — Crew fitness suite | Full discussion produces expected accuracy + timing | Consensus protocol, orchestration, multi-agent synthesis |

A Layer 1 failure explains Layer 2 and 3 noise: if an agent's MCP is broken, the agent will stand-aside or fabricate. Layer 1 isolates that without involving an LLM.

## Per-server definition format (proposed)

One YAML file per MCPServer CR, named after the server:

```yaml
# proxmox.yaml — smoke tests for proxmox-mcp
server: proxmox-mcp
namespace: crew-homelab-pilot
description: Proxmox API tools via Proxmox MCP server

# Test plan per tool. Tools not listed here are auto-verified as "present in tools/list".
tools:
  - name: get_nodes
    invoke: true
    input: {}
    assert:
      - kind: not_error
      - kind: response_contains
        value: pve   # at least one node name we know exists

  - name: get_vms
    invoke: true
    input:
      node: pve     # parameterize as needed
    assert:
      - kind: not_error

  - name: shutdown_vm
    invoke: false    # destructive — verify it's registered but don't call
    assert:
      - kind: listed_in_tools
```

### Assertion kinds

- `not_error` — MCP response is not a JSON-RPC error
- `response_contains: <string>` — response body (string-rendered) contains the substring
- `response_matches: <regex>` — response body matches the regex
- `listed_in_tools` — tool appears in the MCP server's `tools/list` response (no invocation)

### Invocation flow (planned runner behavior)

1. Open MCP session to `<server>.<namespace>.svc.cluster.local:<port>` (the operator manages the Service for each MCPServer)
2. Send `initialize` + `notifications/initialized`
3. Call `tools/list` — enumerate advertised tools
4. For each tool in the test plan with `invoke: true`: call `tools/call` with the input and run assertions
5. For each tool with `invoke: false`: verify it appears in `tools/list`
6. Report pass/fail per tool, plus any tools that appear in `tools/list` but are missing from the plan (drift warning)

## Currently sketched

| File | Status |
|---|---|
| `proxmox.yaml` | Starter draft — verify tool list and basic node enumeration |
| `kubernetes.yaml` | Starter draft — verify tool list and pod/namespace reads |

The other servers (k8sgpt, prometheus, scheduling, kubernetes-rbac) need their tool inventories cataloged before a useful test plan can be written. Best done by running each server's `tools/list` once against the live cluster and pasting the output as a starting point.

## When to add a test

- New MCPServer lands in the crew → add a `{server-name}.yaml` here covering its read-only tools
- A regression escapes (e.g., the Proxmox secret outage) → add a tool invocation that would have caught it
- A new tool is registered on an existing server → add it to the plan (drift warning will flag the gap until you do)
