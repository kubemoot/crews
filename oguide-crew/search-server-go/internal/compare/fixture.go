package compare

import (
	"encoding/json"
	"fmt"
	"hash/fnv"
	"io"
	"math/bits"
	"net/http"
	"sort"
	"strings"
)

const (
	alexWriter     = "Alex Writer"
	relevanceScore = "relevance_score"
)

// Fixture is a stand-in for the crew's MCP gateway whose answers are a fixed function of the search
// arguments, so both servers get the same catalog and any difference is the servers'. It holds no
// credential and checks none. It serves POST /tools/<tool>/call as the crew's gateway does.
type Fixture struct{}

type fixtureCall struct {
	Arguments map[string]any `json:"arguments"`
}

// ServeHTTP answers a tool call with {"isError": false, "content": "<tool text>"}.
func (Fixture) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	data, _ := io.ReadAll(r.Body)
	var call fixtureCall
	if err := json.Unmarshal(data, &call); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	tool := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/tools/"), "/call")
	content := expertText(tool, call.Arguments)
	if tool == "search_oreilly_content" {
		content = searchText(call.Arguments)
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"isError": false, "content": content})
}

func expertText(tool string, arguments map[string]any) string {
	text, _ := json.Marshal(map[string]any{"tool": tool, "arguments": arguments, "results": []any{}})
	return string(text)
}

type catalogItem map[string]any

func slug(title string) string {
	return strings.ReplaceAll(strings.ToLower(title), " ", "-")
}

func fixtureItem(title, date string, authors []string, extra map[string]any) catalogItem {
	item := catalogItem{"title": title, "authors": authors, "marketing_type": "book", "publication_date": date,
		"url":        "https://learning.oreilly.com/library/view/-/" + slug(title) + "/",
		"page_count": 320, "publisher_names": []string{"Fixture Press"}, "tags": []string{"fixture"}}
	for key, value := range extra {
		item[key] = value
	}
	return item
}

func fixtureEvent(title string, sessions []string, authors []string) catalogItem {
	return fixtureItem(title, "2026-08-01", authors, map[string]any{"marketing_type": "live course",
		"live_event_start_dates": sessions, "page_count": nil,
		"url": "https://learning.oreilly.com/live-events/-/" + slug(title) + "/"})
}

// searchText is the text of a search_oreilly_content reply for these arguments.
func searchText(arguments map[string]any) string {
	items := fixtureItems(arguments)
	if len(items) == 0 {
		return `{"search_results": []}`
	}
	// Keys are written in a fixed order that is not sorted, as the catalog's urns are.
	keys := make([]string, 0, len(items))
	for key := range items {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(a, b int) bool { return scramble(keys[a]) < scramble(keys[b]) })
	var out strings.Builder
	out.WriteString(`{"search_results": {`)
	for i, key := range keys {
		if i > 0 {
			out.WriteString(", ")
		}
		value, _ := json.Marshal(items[key])
		fmt.Fprintf(&out, "%q: %s", key, value)
	}
	out.WriteString("}}")
	return out.String()
}

// scramble is a fixed order for the keys that is not their sorted order.
func scramble(key string) uint32 {
	hash := fnv.New32a()
	_, _ = hash.Write([]byte(key))
	return bits.Reverse32(hash.Sum32())
}

func stringsOf(value any) []string {
	var out []string
	switch v := value.(type) {
	case []any:
		for _, one := range v {
			out = append(out, fmt.Sprint(one))
		}
	case []string:
		out = v
	}
	return out
}

// fixtureItems are the catalog's items for one search, keyed by urn.
func fixtureItems(arguments map[string]any) map[string]catalogItem {
	types := stringsOf(arguments["content_types"])
	query, _ := arguments["query"].(string)
	authors := stringsOf(arguments["author_filter"])
	switch {
	case len(types) == 1 && types[0] == "live-events":
		return liveItems(query, authors)
	case len(authors) > 0:
		return authorItems(authors[0], types, arguments)
	case arguments["date_range"] == nil:
		return titleItems(query)
	default:
		return topicItems(query, arguments)
	}
}

func liveItems(query string, authors []string) map[string]catalogItem {
	who := []string{"Pat Teacher"}
	if len(authors) > 0 {
		who = authors
	} else if strings.Contains(strings.ToLower(query), "neal ford") {
		who = []string{"Neal Ford"}
	}
	return map[string]catalogItem{
		"urn:live:1": fixtureEvent("Live Agents Workshop", []string{"2026-12-10T16:00:00Z", "2026-12-11T16:00:00Z"}, who),
		"urn:live:2": fixtureEvent("Live Kubernetes Day", []string{"2026-11-25T14:00:00Z"}, who),
		"urn:live:3": fixtureEvent("Live Past Series", []string{"2026-10-01T14:00:00Z"}, who),
	}
}

func rangeOf(arguments map[string]any) (end, start string) {
	rng, _ := arguments["date_range"].(map[string]any)
	end, _ = rng["end_date"].(string)
	start, _ = rng["start_date"].(string)
	return end, start
}

func released(arguments map[string]any) bool {
	end, _ := rangeOf(arguments)
	return end != ""
}

func authorItems(author string, types []string, arguments map[string]any) map[string]catalogItem {
	if len(types) == 1 && types[0] == "books" {
		return datedItems(author+" Book", []string{author}, arguments, 3)
	}
	items := datedItems(author+" Video", []string{author}, arguments, 2)
	for _, item := range items {
		item["marketing_type"], item["duration"] = "on-demand course", 9089
	}
	return items
}

func topicItems(query string, arguments map[string]any) map[string]catalogItem {
	who := []string{alexWriter, "Sam Coauthor"}
	if strings.EqualFold(query, "Neal Ford") || strings.EqualFold(query, "Neal Ford forthcoming") {
		who = []string{"Neal Ford"}
		return datedItems("Architecture", who, arguments, 4)
	}
	return datedItems(query, who, arguments, 5)
}

func titleItems(query string) map[string]catalogItem {
	return map[string]catalogItem{
		"urn:title:1": fixtureItem(query+" Second Edition", "2026-11-30", []string{alexWriter},
			map[string]any{relevanceScore: 0.91}),
		"urn:title:2": fixtureItem(query+" First Edition", "2019-04-01", []string{alexWriter},
			map[string]any{relevanceScore: 0.87}),
		"urn:title:3": fixtureItem("A Different Book About "+query, "2022-02-02", []string{"Sam Coauthor"},
			map[string]any{relevanceScore: 0.12}),
	}
}

// datedItems are count items for a topic or a name, each dated on the side of today the search asks.
func datedItems(label string, authors []string, arguments map[string]any, count int) map[string]catalogItem {
	items := map[string]catalogItem{}
	for i := 1; i <= count; i++ {
		date := fmt.Sprintf("2026-%02d-%02d", 12-i, 20-i)
		if released(arguments) {
			date = fmt.Sprintf("2025-%02d-%02d", 12-i, 20-i)
		}
		title := fmt.Sprintf("%s %d", label, i)
		items[fmt.Sprintf("urn:%s:%d", strings.ToLower(strings.ReplaceAll(label, " ", "-")), i)] =
			fixtureItem(title, date, authors, nil)
	}
	return items
}
