package server

import (
	"bytes"
	"io"
	"net/http"
	"strings"
	"testing"
)

func ask(t *testing.T, c Catalog, name, arguments string, expert bool) m {
	t.Helper()
	return rpc(t, newServer(c, Config{Expert: expert}), toolCall(name, arguments, ""))
}

func askResult(t *testing.T, c Catalog, name, arguments string) (string, bool) {
	t.Helper()
	return callTextRaw(t, newServer(c, Config{Expert: true}), toolCall(name, arguments, ""))
}

func TestTheExpertToolsAreListedOnlyWhenExpertIsOn(t *testing.T) {
	listing := `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`
	names := func(expert bool) []string {
		out := make([]string, 0, 7)
		for _, tool := range rpc(t, newServer(answers(), Config{Expert: expert}), listing)["result"].(m)["tools"].([]any) {
			out = append(out, tool.(m)["name"].(string))
		}
		return out
	}
	off, on := names(false), names(true)
	equal(t, 5, len(off))
	equal(t, []string{"ask_experts", "get_citation"}, on[5:])
}

func TestTheToolsUseNamesThatDoNotCollideWithTheUpstreamTools(t *testing.T) {
	upstream := map[string]bool{searchTool: true, askTool: true, citationTool: true}
	for _, tool := range expertTools {
		isTrue(t, !upstream[tool.Name], tool.Name)
	}
	for _, tool := range searchTools {
		isTrue(t, !upstream[tool.Name], tool.Name)
	}
}

func TestAnExpertCallIsRefusedWhenExpertIsOff(t *testing.T) {
	out := ask(t, &recordingCatalog{}, "ask_experts", `{"question":"q"}`, false)
	equal(t, float64(-32602), out["error"].(m)["code"])
}

func TestAQuestionGoesUpstreamWithItsFilters(t *testing.T) {
	catalog := &recordingCatalog{text: `{"results": {"results": []}}`}
	text, failed := askResult(t, catalog, "ask_experts",
		`{"question":" What is a fixture? ","author":"A. Author","max_results":3,"junk":"dropped","context":null}`)
	equal(t, []expertCall{{"ask_oreilly_experts", m{"question": "What is a fixture?", "author": "A. Author",
		"max_results": jsonNumber("3")}}}, catalog.calls)
	isTrue(t, !failed, "not an error")
	equal(t, `{"results": {"results": []}}`, text)
}

func TestACitationGoesUpstreamByProductAndOffset(t *testing.T) {
	catalog := &recordingCatalog{text: "snippet text"}
	text, _ := askResult(t, catalog, "get_citation", `{"product_id":"9781098139575","offset":662}`)
	equal(t, []expertCall{{"get_oreilly_citation", m{"product_id": "9781098139575", "offset": jsonNumber("662")}}},
		catalog.calls)
	equal(t, "snippet text", text)
}

func TestAnOffsetOfZeroIsSent(t *testing.T) {
	catalog := &recordingCatalog{text: "ok"}
	_, failed := askResult(t, catalog, "get_citation", `{"product_id":"1","offset":0}`)
	isTrue(t, !failed, "zero is a whole number")
	equal(t, 1, len(catalog.calls))
}

func TestMalformedArgumentsAreErrorsAndCallNothing(t *testing.T) {
	long := strings.Repeat("x", 1001)
	cases := []struct{ name, arguments string }{
		{"ask_experts", `{}`}, {"ask_experts", `{"question":"  "}`}, {"ask_experts", `{"question":"` + long + `"}`},
		{"ask_experts", `{"question":5}`}, {"ask_experts", `{"question":"q","max_results":"3"}`},
		{"ask_experts", `{"question":"q","max_results":true}`}, {"ask_experts", `{"question":"q","max_results":2.5}`},
		{"ask_experts", `{"question":"q","max_results":3.0}`}, {"get_citation", `{"product_id":"1"}`},
		{"get_citation", `{"offset":1}`}, {"get_citation", `{"product_id":["1"],"offset":[1]}`},
		{"ask_experts", `["q"]`},
	}
	for _, c := range cases {
		catalog := &recordingCatalog{}
		_, failed := askResult(t, catalog, c.name, c.arguments)
		isTrue(t, failed, c.name+" "+c.arguments)
		equal(t, 0, len(catalog.calls), c.name+" "+c.arguments)
	}
}

func TestAnAccountWithoutTheEntitlementGetsAPlainToolResult(t *testing.T) {
	catalog := &recordingCatalog{err: entitlementErr()}
	for name, arguments := range map[string]string{"ask_experts": `{"question":"q"}`,
		"get_citation": `{"product_id":"1","offset":0}`} {
		text, failed := askResult(t, catalog, name, arguments)
		isTrue(t, failed, name)
		contains(t, text, "does not include Expert Intelligence")
	}
}

func TestAGatewayReplyCarryingThe403BodyIsTheSamePlainResult(t *testing.T) {
	g := newStubGateway(t)
	g.reply = m{"isError": true, "content": `Error: HTTP 403: {"error":"forbidden","error_description":` +
		`"The 'xmcp' (Expert MCP) permission is required."}`}
	text, failed := askResult(t, g.catalog(), "ask_experts", `{"question":"q"}`)
	isTrue(t, failed, "an error")
	equal(t, noExpertAccess, text)
	isTrue(t, !strings.Contains(text, "xmcp"), "the gateway's body is not shown")
}

func TestAnHTTP403FromTheGatewayIsTheSamePlainResult(t *testing.T) {
	g := newStubGateway(t)
	g.status = http.StatusForbidden
	text, _ := askResult(t, g.catalog(), "get_citation", `{"product_id":"1","offset":0}`)
	equal(t, noExpertAccess, text)
}

func TestASearchOnARefusedAccountSaysTheSameAndDoesNotCrash(t *testing.T) {
	text, failed := callTextRaw(t, newServer(failing(entitlementErr()), Config{}),
		toolCall("find_released", `{"topic":"x"}`, ""))
	isTrue(t, failed, "an error")
	equal(t, noExpertAccess, text)
}

func TestAnotherUpstreamFailureIsAnErrorNamingTheExpertTools(t *testing.T) {
	text, failed := askResult(t, &recordingCatalog{err: catalogErr("the gateway answered HTTP 502")}, "ask_experts",
		`{"question":"q"}`)
	isTrue(t, failed, "an error")
	contains(t, text, "Expert tools could not answer")
	isTrue(t, !strings.Contains(text, "Expert Intelligence"), "not the entitlement message")
}

func TestAnUnrelatedFailureIsNotTakenForARefusal(t *testing.T) {
	g := newStubGateway(t)
	g.reply = m{"isError": true, "content": "Error: HTTP 500: upstream down"}
	found := searchError(t, g.catalog())
	isTrue(t, !found.Entitlement, "not an entitlement error")
}

func TestTheForbiddenPatternMatchesWhatTheGatewayWrites(t *testing.T) {
	for _, text := range []string{"Error: HTTP 403: nope", "the xmcp permission", "Forbidden", "refused this call"} {
		isTrue(t, forbiddenPattern.MatchString(text), text)
	}
	for _, text := range []string{"HTTP 500", "a forbiddenly long word", "ok"} {
		isTrue(t, !forbiddenPattern.MatchString(text), text)
	}
}

func TestTheExpertToolsListTheirSchemasWithTheRequiredArguments(t *testing.T) {
	for _, tool := range expertTools {
		schema := tool.InputSchema
		equal(t, "object", schema["type"], tool.Name)
		isTrue(t, len(schema["required"].([]any)) > 0, tool.Name)
	}
	equal(t, []any{"question"}, expertTools[0].InputSchema["required"])
	equal(t, []any{"product_id", "offset"}, expertTools[1].InputSchema["required"])
}

func TestAnExpertReplyThatIsNotTheGatewayShapeIsAClearFailure(t *testing.T) {
	g := newStubGateway(t)
	g.handle = func(w http.ResponseWriter, _ *http.Request) { _, _ = io.WriteString(w, `{"nope":1}`) }
	text, failed := askResult(t, g.catalog(), "ask_experts", `{"question":"q"}`)
	isTrue(t, failed, "an error")
	contains(t, text, "shape this server does not know")
}

func TestAnExpertToolFailureOtherThanACatalogErrorIsAnInternalError(t *testing.T) {
	var out bytes.Buffer
	in := toolCall("ask_experts", `{"question":"q"}`, "") + "\n"
	_ = newServer(&brokenExpert{}, Config{Expert: true}).Serve(strings.NewReader(in), &out)
	contains(t, out.String(), "-32603")
}

type brokenExpert struct{ recordingCatalog }

func (*brokenExpert) Call(string, map[string]any) (string, error) { return "", io.ErrUnexpectedEOF }
