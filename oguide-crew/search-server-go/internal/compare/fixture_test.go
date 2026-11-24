package compare

import (
	"encoding/json"
	"net/http/httptest"
	"regexp"
	"sort"
	"strings"
	"testing"
)

func ask(t *testing.T, tool, body string) map[string]any {
	t.Helper()
	srv := httptest.NewServer(Fixture{})
	defer srv.Close()
	request := httptest.NewRequest("POST", "/tools/"+tool+"/call", strings.NewReader(body))
	recorder := httptest.NewRecorder()
	Fixture{}.ServeHTTP(recorder, request)
	var reply map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &reply); err != nil {
		t.Fatalf("not JSON: %s", recorder.Body.String())
	}
	return reply
}

func TestTheFixtureAnswersLikeTheGateway(t *testing.T) {
	reply := ask(t, "search_oreilly_content", `{"arguments":{"query":"rust","n_items":25,"date_range":{"end_date":"2026-11-23"}}}`)
	if reply["isError"] != false {
		t.Fatalf("want a success, got %v", reply)
	}
	var results map[string]map[string]any
	if err := json.Unmarshal([]byte(reply["content"].(string)), &results); err != nil || len(results["search_results"]) == 0 {
		t.Fatalf("want results, got %v (%v)", reply["content"], err)
	}
}

func TestTheFixtureIsAFixedFunctionOfTheArguments(t *testing.T) {
	body := `{"arguments":{"query":"x","author_filter":["Neal Ford"],"content_types":["books"],"date_range":{"end_date":"d"}}}`
	first, second := ask(t, "search_oreilly_content", body), ask(t, "search_oreilly_content", body)
	if first["content"] != second["content"] {
		t.Fatal("the same search must give the same text")
	}
}

func TestTheFixtureWritesItsItemsInANonAlphabeticalOrder(t *testing.T) {
	content := ask(t, "search_oreilly_content", `{"arguments":{"query":"x","date_range":{"end_date":"d"}}}`)["content"].(string)
	matches := regexp.MustCompile(`"(urn:x:\d)"`).FindAllStringSubmatch(content, -1)
	written := make([]string, 0, len(matches))
	for _, match := range matches {
		written = append(written, match[1])
	}
	if len(written) != 5 || sort.StringsAreSorted(written) {
		t.Fatalf("the urns must be written in an order that is not sorted, got %v", written)
	}
}

func TestTheFixtureAnswersTheExpertToolsAndBadRequests(t *testing.T) {
	reply := ask(t, "ask_oreilly_experts", `{"arguments":{"question":"q"}}`)
	if !strings.Contains(reply["content"].(string), `"question":"q"`) {
		t.Fatalf("the Expert text echoes the arguments, got %v", reply)
	}
	recorder := httptest.NewRecorder()
	Fixture{}.ServeHTTP(recorder, httptest.NewRequest("POST", "/tools/x/call", strings.NewReader("not json")))
	if recorder.Code != 400 {
		t.Fatalf("want 400, got %d", recorder.Code)
	}
}

func TestTheFixtureFindsNothingForAnUnknownLiveSearchShape(t *testing.T) {
	if got := searchText(map[string]any{"content_types": []any{"live-events"}, "author_filter": []any{"Ann Author"}}); !strings.Contains(got, "Ann Author") {
		t.Fatalf("live events carry the author asked for, got %s", got)
	}
	if got := stringsOf(nil); got != nil {
		t.Fatalf("no strings, got %v", got)
	}
}
