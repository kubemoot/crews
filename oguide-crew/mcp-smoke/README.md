# MCP tool smoke inputs: oguide-crew

Kubemoot runs a tool smoke first in every CrewFitnessSuite: it lists the tools of each
MCPServer in the crew's namespace through the crew's MCP gateway and calls each tool that
declares a test input. No model runs. A failing tool stops the suite with phase
`ToolSmokeFailed`; a tool with no input is only checked for being listed.

Each `<server>.yaml` holds the `smokeInputs` of one MCPServer, rendered into its
`spec.smokeInputs` by `oguide-crew.smokeInputs` (`templates/_helpers.tpl`) after `tpl`.
Declare only read-only tools with read-only arguments. The workspace server is left to the
listing check because its tools need the discussion's workspace scope; the raw O'Reilly
server is exercised through the search server's call.
