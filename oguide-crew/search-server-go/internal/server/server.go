// Package server is the O'guide search server: fixed O'Reilly catalog searches as an MCP server
// over stdio. It builds every search argument itself (the date filters, the item count, the
// ordering), labels each item Released or Scheduled from its own date against the requester's
// date, and sorts the results. It holds no credential: it calls the raw search tool through the
// crew's MCP gateway, which adds the O'Reilly credential to each outbound request.
package server

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	serverName       = "oguide-search"
	protocolVersion  = "2025-03-26"
	maxArgumentChars = 300
	jsonRPC          = "2.0"

	codeInvalidRequest = -32600
	codeMethodNotFound = -32601
	codeInvalidParams  = -32602
	codeParseError     = -32700
	codeInternalError  = -32603
)

// Config is what a server is started with.
type Config struct {
	// DefaultZone is the IANA zone whose date is "today" when a request carries none.
	DefaultZone string
	// Expert offers ask_experts and get_citation beside the five searches.
	Expert bool
	// Note is appended to every tool description (the per-person access sentence).
	Note string
	// Now is the clock; nil is the system clock.
	Now func() time.Time
}

// Server answers MCP messages for the five searches (and the Expert tools when on).
type Server struct {
	catalog Catalog
	config  Config
	recent  *Recent
}

// New is a server that searches through catalog.
func New(catalog Catalog, config Config) *Server {
	if config.Now == nil {
		config.Now = time.Now
	}
	if config.DefaultZone == "" {
		config.DefaultZone = "UTC"
	}
	return &Server{catalog: catalog, config: config, recent: NewRecent(config.Now, repeatWindow, maxRemembered)}
}

// toolResult is a tools/call result: one text block and whether it is an error.
type toolResult struct {
	Text    string
	IsError bool
}

func textResult(text string, isError bool) toolResult {
	return toolResult{Text: text, IsError: isError}
}

func (r toolResult) wire() map[string]any {
	return map[string]any{"content": []any{map[string]any{"type": "text", "text": r.Text}}, "isError": r.IsError}
}

func toolNamed(name string) (toolSpec, bool) {
	for _, tool := range searchTools {
		if tool.Name == name {
			return tool, true
		}
	}
	return toolSpec{}, false
}

func toolListing(note string) []any {
	listing := make([]any, 0, len(searchTools))
	for _, tool := range searchTools {
		listing = append(listing, map[string]any{
			fieldName: tool.Name, fieldDescription: withNote(tool.Description, note),
			"inputSchema": map[string]any{
				fieldType: "object",
				"properties": map[string]any{tool.Argument: map[string]any{
					fieldType: "string", fieldDescription: tool.ArgumentDescription}},
				"required": []string{tool.Argument},
			},
		})
	}
	return listing
}

// argumentOf is the tool's single argument, trimmed, or false when it is missing, not text, or
// too long.
func argumentOf(name string, arguments any) (string, bool) {
	spec, _ := toolNamed(name)
	given, _ := arguments.(map[string]any)
	value, isText := given[spec.Argument].(string)
	if !isText || strings.TrimSpace(value) == "" || utf8.RuneCountInString(value) > maxArgumentChars {
		return "", false
	}
	return strings.TrimSpace(value), true
}

// withNothingFound adds a plain "nothing found" message when a search returned no items.
func withNothingFound(payload *obj, value, today string) *obj {
	if payload.has(keyMessage) {
		return payload
	}
	for _, key := range payload.keys {
		if isList(payload.get(key)) && listLen(payload.get(key)) > 0 {
			return payload
		}
	}
	return payload.set(keyMessage, "Nothing found for '"+value+"' in the O'Reilly catalog as of "+today+".")
}

// callContext is what one search call knows besides its argument.
type callContext struct {
	today, source string
	meta          any
}

func (s *Server) callSearch(name string, arguments any, c Catalog, ctx callContext) (toolResult, error) {
	value, ok := argumentOf(name, arguments)
	if !ok {
		return textResult(fmt.Sprintf("%s needs its one text argument (at most %d characters)", name,
			maxArgumentChars), true), nil
	}
	key := callKey(name, value, ctx.meta)
	if earlier := s.recent.earlier(key); earlier != nil {
		return jsonResult(newObj().set("repeat", repeatNote), earlier)
	}
	found, err := handlers[name](c, value, ctx.today)
	if err != nil {
		return searchFailure(err)
	}
	payload := newObj().set("today", ctx.today).set("dateSource", ctx.source)
	merged := withNothingFound(found, value, ctx.today)
	for _, k := range merged.keys {
		payload.set(k, merged.get(k))
	}
	s.recent.remember(key, payload)
	return jsonResult(payload, nil)
}

// jsonResult is the text result of the objects' keys in order, a second object after the first.
func jsonResult(first, second *obj) (toolResult, error) {
	merged := newObj()
	for _, part := range []*obj{first, second} {
		if part == nil {
			continue
		}
		for _, key := range part.keys {
			merged.set(key, part.get(key))
		}
	}
	text, err := encodeJSON(merged)
	return textResult(text, false), err
}

// searchFailure is the result the model reads when a search failed, or the error when the failure
// is not one this server explains.
func searchFailure(err error) (toolResult, error) {
	var shape *shapeError
	if errors.As(err, &shape) {
		return textResult("The O'Reilly catalog could not be searched: it answered in a shape this server "+
			"does not know", true), nil
	}
	found, isCatalog := asCatalogError(err)
	switch {
	case !isCatalog:
		return toolResult{}, err
	case found.Entitlement:
		return textResult(found.Msg, true), nil
	default:
		return textResult("The O'Reilly catalog could not be searched: "+found.Msg, true), nil
	}
}

func errorReply(ident any, code int, text string) map[string]any {
	return map[string]any{"jsonrpc": jsonRPC, "id": ident, "error": map[string]any{"code": code, "message": text}}
}

func (s *Server) scoped(meta any) Catalog {
	if narrow, ok := s.catalog.(scopable); ok {
		return narrow.Scoped(meta)
	}
	return s.catalog
}

// Handle is the reply to one JSON-RPC message, or nil for a notification. An error is a failure
// this server does not explain to the caller (the serve loop answers it as an internal error).
func (s *Server) Handle(message any) (map[string]any, error) {
	request, isObject := message.(map[string]any)
	if !isObject {
		return errorReply(nil, codeInvalidRequest, "a request is a JSON object"), nil
	}
	method, _ := request["method"].(string)
	ident := request["id"]
	params, _ := request["params"].(map[string]any)
	if ident == nil {
		return nil, nil
	}
	result, err := s.dispatch(method, params)
	if err != nil {
		return nil, err
	}
	if result == nil {
		code := codeMethodNotFound
		if method == "tools/call" {
			code = codeInvalidParams
		}
		return errorReply(ident, code, "cannot handle that request"), nil
	}
	return map[string]any{"jsonrpc": jsonRPC, "id": ident, "result": result}, nil
}

// dispatch is the result of a method, or nil when this server does not handle it.
func (s *Server) dispatch(method string, params map[string]any) (any, error) {
	switch method {
	case "initialize":
		version := protocolVersion
		if truthy(params["protocolVersion"]) {
			version = pyStr(params["protocolVersion"])
		}
		return map[string]any{"protocolVersion": version,
			"capabilities": map[string]any{"tools": map[string]any{"listChanged": false}},
			"serverInfo":   map[string]any{"name": serverName, "version": "1"}}, nil
	case "ping":
		return map[string]any{}, nil
	case "tools/list":
		tools := toolListing(s.config.Note)
		if s.config.Expert {
			tools = append(tools, expertListing(s.config.Note)...)
		}
		return map[string]any{"tools": tools}, nil
	case "tools/call":
		return s.callTool(params)
	default:
		return nil, nil
	}
}

func (s *Server) callTool(params map[string]any) (any, error) {
	name, _ := params["name"].(string)
	meta := params["_meta"]
	if _, isSearch := handlers[name]; isSearch {
		today, source := resolveToday(meta, s.config.DefaultZone, s.config.Now())
		result, err := s.callSearch(name, params["arguments"], s.scoped(meta), callContext{today, source, meta})
		return wireOf(result, err)
	}
	if tool, isExpert := expertNamed(name); isExpert && s.config.Expert {
		result, err := callExpert(tool, params["arguments"], s.scoped(meta))
		return wireOf(result, err)
	}
	return nil, nil
}

func wireOf(result toolResult, err error) (any, error) {
	if err != nil {
		return nil, err
	}
	return result.wire(), nil
}

// Serve answers one JSON message per line of in, and writes one reply per line to out, until in
// ends. One bad message never ends the process the bridge talks to.
func (s *Server) Serve(in io.Reader, out io.Writer) error {
	reader := bufio.NewReader(in)
	for {
		line, readErr := reader.ReadBytes('\n')
		if len(bytes.TrimSpace(line)) > 0 {
			if err := writeReply(out, s.answer(line)); err != nil {
				return err
			}
		}
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				return nil
			}
			return readErr
		}
	}
}

func writeReply(out io.Writer, reply map[string]any) error {
	if reply == nil {
		return nil
	}
	text, err := encodeJSON(reply)
	if err != nil {
		text, _ = encodeJSON(errorReply(nil, codeInternalError, "internal error"))
	}
	_, err = io.WriteString(out, text+"\n")
	return err
}

// answer is the reply to one line: a parse error for text that is not JSON, an internal error
// for a message that failed in a way this server does not explain.
func (s *Server) answer(line []byte) (reply map[string]any) {
	defer func() {
		if recover() != nil {
			reply = errorReply(nil, codeInternalError, "internal error")
		}
	}()
	var message any
	if err := decodeJSON(bytes.TrimSpace(line), &message); err != nil {
		return errorReply(nil, codeParseError, "parse error")
	}
	reply, err := s.Handle(message)
	if err != nil {
		return errorReply(nil, codeInternalError, "internal error")
	}
	return reply
}
