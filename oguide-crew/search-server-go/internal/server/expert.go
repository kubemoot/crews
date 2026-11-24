package server

import (
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

const maxQuestionChars = 1000

// expertParam is one argument of an Expert tool, in the order they are checked.
type expertParam struct {
	name string
	text bool
}

// expertTool is an Expert tool this server offers over one of O'Reilly's Expert MCP tools.
type expertTool struct {
	Name        string         `json:"name"`
	Upstream    string         `json:"upstream"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
	params      []expertParam
	required    []string
}

var expertTools = withParams(definitions.Expert)

// withParams reads the checked arguments and the required ones from each tool's input schema, the
// schema the model sees. Arguments are checked in name order.
func withParams(tools []expertTool) []expertTool {
	for i := range tools {
		properties, _ := tools[i].InputSchema["properties"].(map[string]any)
		names := make([]string, 0, len(properties))
		for name := range properties {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			spec, _ := properties[name].(map[string]any)
			tools[i].params = append(tools[i].params, expertParam{name, spec["type"] == "string"})
		}
		required, _ := tools[i].InputSchema["required"].([]any)
		for _, key := range required {
			tools[i].required = append(tools[i].required, fmt.Sprint(key))
		}
	}
	return tools
}

func expertNamed(name string) (expertTool, bool) {
	for _, tool := range expertTools {
		if tool.Name == name {
			return tool, true
		}
	}
	return expertTool{}, false
}

// withNote is the tool description with the access sentence appended, when there is one.
func withNote(description, note string) string {
	if note != "" && !strings.Contains(description, note) {
		return description + " " + note
	}
	return description
}

func expertListing(note string) []any {
	listing := make([]any, 0, len(expertTools))
	for _, tool := range expertTools {
		listing = append(listing, map[string]any{fieldName: tool.Name, fieldDescription: withNote(tool.Description, note),
			"inputSchema": tool.InputSchema})
	}
	return listing
}

// wholeNumber is the value as a JSON integer, when it is one (a true or a 5.0 is not).
func wholeNumber(value any) (any, bool) {
	switch v := value.(type) {
	case json.Number:
		_, err := strconv.ParseInt(v.String(), 10, 64)
		return v, err == nil
	case int:
		return v, true
	case int64:
		return v, true
	default:
		return nil, false
	}
}

// expertArguments are the upstream arguments for an Expert tool, or the reason the call is
// malformed. Arguments the tool does not name, and null ones, are dropped.
func expertArguments(tool expertTool, arguments any) (map[string]any, string) {
	given, ok := arguments.(map[string]any)
	if !ok {
		return nil, tool.Name + " needs its arguments as an object"
	}
	sent := map[string]any{}
	for _, param := range tool.params {
		value := given[param.name]
		if value == nil {
			continue
		}
		clean, problem := checkExpertValue(param, value)
		if problem != "" {
			return nil, problem
		}
		sent[param.name] = clean
	}
	var missing []string
	for _, key := range tool.required {
		if _, found := sent[key]; !found {
			missing = append(missing, key)
		}
	}
	if len(missing) > 0 {
		return nil, tool.Name + " needs " + strings.Join(missing, ", ")
	}
	return sent, ""
}

func checkExpertValue(param expertParam, value any) (any, string) {
	if !param.text {
		whole, ok := wholeNumber(value)
		if !ok {
			return nil, param.name + " must be a whole number"
		}
		return whole, ""
	}
	text, isText := value.(string)
	if !isText || strings.TrimSpace(text) == "" || utf8.RuneCountInString(text) > maxQuestionChars {
		return nil, param.name + " must be text of at most " + strconv.Itoa(maxQuestionChars) + " characters"
	}
	return strings.TrimSpace(text), ""
}

// callExpert is a tools/call result for an Expert tool: O'Reilly's passages as returned, or an
// error to read.
func callExpert(tool expertTool, arguments any, c Catalog) (toolResult, error) {
	sent, problem := expertArguments(tool, arguments)
	if sent == nil {
		return textResult(problem, true), nil
	}
	text, err := c.Call(tool.Upstream, sent)
	if err == nil {
		return textResult(text, false), nil
	}
	found, isCatalog := asCatalogError(err)
	switch {
	case !isCatalog:
		return toolResult{}, err
	case found.Entitlement:
		return textResult(found.Msg, true), nil
	default:
		return textResult("The O'Reilly Expert tools could not answer: "+found.Msg, true), nil
	}
}
