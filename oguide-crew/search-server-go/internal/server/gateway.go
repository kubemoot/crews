package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	searchTool          = "search_oreilly_content"
	askTool             = "ask_oreilly_experts"
	citationTool        = "get_oreilly_citation"
	timeout             = 15 * time.Second
	maxReplyBytes       = 5_000_000
	maxUpstreamChars    = 160
	maxRelayedChars     = 256
	keyConversationID   = "conversationId"
	keyPrincipalID      = "principalId"
	forbiddenPatternRaw = `(?i)HTTP 403|xmcp|\bforbidden\b|refused this call`
)

var forbiddenPattern = regexp.MustCompile(forbiddenPatternRaw)

// CatalogError means the O'Reilly catalog could not be searched. The message is written for the
// model to read. Entitlement marks the one the model must be told plainly: O'Reilly refused the
// account (HTTP 403), which has no Expert MCP entitlement.
type CatalogError struct {
	Msg         string
	Entitlement bool
}

func (e *CatalogError) Error() string { return e.Msg }

func catalogErr(format string, args ...any) error {
	return &CatalogError{Msg: fmt.Sprintf(format, args...)}
}

// unreachableErr says the gateway could not be reached, and the kind of failure.
func unreachableErr(kind string) error {
	return catalogErr("the gateway is unreachable (%s)", kind)
}

func entitlementErr() error {
	return &CatalogError{Msg: noExpertAccess, Entitlement: true}
}

// asCatalogError is the catalog error in err's chain, when there is one.
func asCatalogError(err error) (*CatalogError, bool) {
	var found *CatalogError
	return found, errors.As(err, &found)
}

// Catalog is where searches go: the crew's MCP gateway, or a fake in a test.
type Catalog interface {
	// Search runs one catalog search and returns its result items.
	Search(arguments map[string]any) ([]map[string]any, error)
	// Call runs one upstream tool and returns the text of its reply.
	Call(tool string, arguments map[string]any) (string, error)
}

// scopable is a Catalog that can carry the asker's context on its gateway calls.
type scopable interface {
	Scoped(meta any) Catalog
}

// GatewayCatalog calls the O'Reilly tools through the crew's MCP gateway. The gateway holds the
// credential and adds it to each outbound request (the subscriber key, or the asking person's own
// token through callerCredential); this process never reads one and sends none.
type GatewayCatalog struct {
	base    string
	client  *http.Client
	relay   bool
	context map[string]string
}

// NewGatewayCatalog is a catalog that calls the gateway at gatewayURL. With relay on, the asker's
// conversationId and principalId, which the gateway relays in params._meta, ride on each call.
func NewGatewayCatalog(gatewayURL string, relay bool) *GatewayCatalog {
	// A user:password in the address would make the HTTP client send a credential; strip it.
	if parsed, err := url.Parse(gatewayURL); err == nil && parsed.User != nil {
		parsed.User = nil
		gatewayURL = parsed.String()
	}
	return &GatewayCatalog{
		base: strings.TrimRight(gatewayURL, "/"), relay: relay,
		client: &http.Client{
			Timeout:       timeout,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
	}
}

// Scoped is a catalog whose gateway calls carry the asker's conversationId and principalId from
// meta. Without relay (the default) it is the catalog itself and nothing is passed on. Only those
// two keys, only as short text, are ever relayed; the gateway decides what they allow.
func (g *GatewayCatalog) Scoped(meta any) Catalog {
	fields, ok := meta.(map[string]any)
	if !g.relay || !ok {
		return g
	}
	relayed := map[string]string{}
	for _, key := range []string{keyConversationID, keyPrincipalID} {
		text, isText := fields[key].(string)
		if isText && text != "" && utf8.RuneCountInString(text) <= maxRelayedChars {
			relayed[key] = text
		}
	}
	scoped := *g
	scoped.context = relayed
	return &scoped
}

// Call runs one upstream tool and returns the text of its reply.
func (g *GatewayCatalog) Call(tool string, arguments map[string]any) (string, error) {
	body := struct {
		Arguments map[string]any    `json:"arguments"`
		Meta      map[string]string `json:"_meta,omitempty"`
	}{arguments, g.context}
	payload, err := json.Marshal(body)
	if err != nil {
		return "", catalogErr("the search could not be written (%v)", err)
	}
	raw, err := g.post(g.base+"/tools/"+tool+"/call", payload)
	if err != nil {
		return "", err
	}
	return contentOf(raw)
}

// post sends one JSON request and returns the reply body, bounded.
func (g *GatewayCatalog) post(target string, payload []byte) ([]byte, error) {
	request, err := http.NewRequestWithContext(context.Background(), http.MethodPost, target, bytes.NewReader(payload))
	if err != nil {
		return nil, unreachableErr("bad address")
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := g.client.Do(request)
	if err != nil {
		return nil, unreachableErr(failureKind(err))
	}
	defer func() { _ = response.Body.Close() }()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 1<<16))
		if response.StatusCode == http.StatusForbidden {
			return nil, entitlementErr()
		}
		return nil, catalogErr("the gateway answered HTTP %d", response.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, maxReplyBytes+1))
	if err != nil {
		return nil, unreachableErr(failureKind(err))
	}
	if len(raw) > maxReplyBytes {
		return nil, catalogErr("the gateway answered with more than this server reads")
	}
	return raw, nil
}

// failureKind names a transport failure for the model without the address or any detail.
func failureKind(err error) string {
	var netErr net.Error
	if errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &netErr) && netErr.Timeout()) {
		return "timeout"
	}
	return "connection failed"
}

// Search runs one catalog search and returns its result items.
func (g *GatewayCatalog) Search(arguments map[string]any) ([]map[string]any, error) {
	text, err := g.Call(searchTool, arguments)
	if err != nil {
		return nil, err
	}
	return itemsIn(text)
}

// short is the first line of an upstream message, bounded, for an error the model can read.
func short(text any) string {
	runes := []rune(strings.Join(strings.Fields(pyStr(text)), " "))
	if len(runes) > maxUpstreamChars {
		runes = runes[:maxUpstreamChars]
	}
	return string(runes)
}

func decodeJSON(data []byte, into any) error {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	if err := dec.Decode(into); err != nil {
		return err
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return errors.New("trailing data")
	}
	return nil
}

// contentOf is the tool text in a gateway tool reply {"isError": bool, "content": "<tool text>"}.
func contentOf(raw []byte) (string, error) {
	var reply map[string]any
	if err := decodeJSON(raw, &reply); err != nil {
		return "", catalogErr("the gateway answered in a shape this server does not know")
	}
	content, found := reply["content"]
	if !found {
		return "", catalogErr("the gateway answered in a shape this server does not know")
	}
	if truthy(reply["isError"]) {
		if forbiddenPattern.MatchString(pyStr(content)) {
			return "", entitlementErr()
		}
		return "", catalogErr("the gateway said: %s", short(content))
	}
	text, isText := content.(string)
	if !isText {
		return "", catalogErr("the catalog did not return results: %s", short(content))
	}
	return text, nil
}

// pyStr is text as the Python server wrote it into a message: None for a missing value.
func pyStr(value any) string {
	if value == nil {
		return "None"
	}
	return fmt.Sprint(value)
}

// itemsIn is the result items in the text of a catalog search. The catalog answers {urn: item}
// when it found items and [] when it found none; the items keep the catalog's order.
func itemsIn(content string) ([]map[string]any, error) {
	results, err := searchResults(content)
	if err != nil {
		return nil, catalogErr("the catalog did not return results: %s", short(content))
	}
	return results, nil
}

// searchResults reads the search_results of the catalog's reply: an object of items (in the order
// the catalog wrote them) or a list of items. Anything that is not an object is skipped.
func searchResults(content string) ([]map[string]any, error) {
	dec := json.NewDecoder(strings.NewReader(content))
	dec.UseNumber()
	if token, err := dec.Token(); err != nil || token != json.Delim('{') {
		return nil, errors.New("not an object")
	}
	for dec.More() {
		keyToken, err := dec.Token()
		if err != nil {
			return nil, err
		}
		if keyToken != "search_results" {
			var skipped json.RawMessage
			if err := dec.Decode(&skipped); err != nil {
				return nil, err
			}
			continue
		}
		return readResultValue(dec)
	}
	return nil, errors.New("no search_results")
}

// openResults reads the opening of the results and returns the delimiter that closes them.
func openResults(dec *json.Decoder) (json.Delim, error) {
	open, err := dec.Token()
	switch {
	case err != nil:
		return 0, err
	case open == json.Delim('{'):
		return json.Delim('}'), nil
	case open == json.Delim('['):
		return json.Delim(']'), nil
	default:
		return 0, errors.New("neither a list nor an object")
	}
}

func readResultValue(dec *json.Decoder) ([]map[string]any, error) {
	closer, err := openResults(dec)
	if err != nil {
		return nil, err
	}
	items := []map[string]any{}
	for dec.More() {
		if closer == json.Delim('}') {
			if _, err := dec.Token(); err != nil {
				return nil, err
			}
		}
		var value any
		if err := dec.Decode(&value); err != nil {
			return nil, err
		}
		if item, isItem := value.(map[string]any); isItem {
			items = append(items, item)
		}
	}
	if end, err := dec.Token(); err != nil || end != closer {
		return nil, errors.New("unterminated")
	}
	return items, nil
}
