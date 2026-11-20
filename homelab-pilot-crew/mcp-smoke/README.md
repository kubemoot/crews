# MCP tool smoke inputs: homelab-pilot-crew

Kubemoot runs a tool smoke first in every CrewFitnessSuite: it lists the tools of each
MCPServer in the crew's namespace through the crew's MCP gateway and calls each tool that
declares a test input. No model runs. A tool that fails stops the suite with phase
`ToolSmokeFailed`. A tool with no input here is only checked for being listed.

Each `<server>.yaml` holds the `smokeInputs` of one MCPServer. The chart renders it into that
server's `spec.smokeInputs` (see `templates/_helpers.tpl`, `homelab-pilot-crew.smokeInputs`),
after running it through `tpl`, so `{{ .Release.Namespace }}` is available. The inputs version
with the server config they cover.

```yaml
smokeInputs:
  - name: list_nodes          # a tool the server lists
    arguments:                # optional, text values by argument name
      node: pve
    timeout: 5s               # optional, default 5s
```

Rules:

- Declare only read-only tools, with read-only arguments. Never declare a tool that changes
  anything, calls a model backend (k8sgpt `analyze`), or needs per-call scope the smoke does
  not send (the workspace tools take the discussion's workspace prefix).
- A server with no file renders no inputs and is only checked for listing its tools.
- `tests/test-smoke-inputs.sh` checks every declared tool is one the server lists
  (`tests/server-tools.yaml`) and that no write tool is declared.
