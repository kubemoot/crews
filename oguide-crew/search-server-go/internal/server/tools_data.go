package server

import (
	_ "embed" // the tool definitions are data, copied word for word from the Python server
	"encoding/json"
)

// The agents' prompts and the fitness scenarios name these tools, so the listing is part of the
// contract: tools.json holds the five searches, the two Expert tools and the plain refusal.
//
//go:embed tools.json
var toolsJSON []byte

// Field names of an MCP tool listing.
const (
	fieldDescription = "description"
	fieldType        = "type"
	fieldName        = "name"
)

type toolSpec struct {
	Name                string `json:"name"`
	Description         string `json:"description"`
	Argument            string `json:"argument"`
	ArgumentDescription string `json:"argumentDescription"`
}

type toolDefinitions struct {
	Search         []toolSpec   `json:"search"`
	Expert         []expertTool `json:"expert"`
	NoExpertAccess string       `json:"noExpertAccess"`
}

var definitions = loadDefinitions()

// searchTools are the five fixed searches, in listing order.
var searchTools = definitions.Search

// noExpertAccess is what the model reads when O'Reilly refuses the account.
var noExpertAccess = definitions.NoExpertAccess

func loadDefinitions() toolDefinitions {
	var loaded toolDefinitions
	if err := json.Unmarshal(toolsJSON, &loaded); err != nil {
		panic("the tool definitions are not valid: " + err.Error())
	}
	return loaded
}
