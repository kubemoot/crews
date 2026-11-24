package compare

import (
	"strings"
	"testing"
)

func text(body string) Answer { return Answer{Text: body} }

var query = Query{Name: "q", Tool: "find_released"}

const stableDay = `"today":"2026-11-23","dateSource":"the request date"`

func list(items ...string) string {
	return `{` + stableDay + `,"released":[` + strings.Join(items, ",") + `]}`
}

func item(url, title string) string {
	return `{"title":"` + title + `","status":"Released","url":"` + url + `"}`
}

func TestTheSameTextIsIdentical(t *testing.T) {
	body := list(item("u1", "A"))
	result := Classify(query, text(body), text(body), text(body))
	if result.Verdict != Identical || len(result.Varies) != 0 {
		t.Fatalf("want identical, got %+v", result)
	}
}

func TestSpacingBetweenJSONTokensIsNotADifference(t *testing.T) {
	spaced := strings.ReplaceAll(list(item("u1", "A")), `":`, `": `)
	result := Classify(query, text(spaced), text(spaced), text(list(item("u1", "A"))))
	if result.Verdict != Identical {
		t.Fatalf("want identical, got %+v", result)
	}
}

func TestADifferentValueWhereTheCatalogIsStableIsDifferent(t *testing.T) {
	result := Classify(query, text(list(item("u1", "A"))), text(list(item("u1", "A"))), text(list(item("u1", "B"))))
	if result.Verdict != Different || len(result.Details) == 0 {
		t.Fatalf("want different with details, got %+v", result)
	}
}

func TestAMissingKeyIsNamed(t *testing.T) {
	a := list(item("u1", "A"))
	b := strings.Replace(a, `"released"`, `"scheduled"`, 1)
	result := Classify(query, text(a), text(a), text(b))
	joined := strings.Join(result.Details, "\n")
	if result.Verdict != Different || !strings.Contains(joined, "only in the python result") ||
		!strings.Contains(joined, "only in the go result") {
		t.Fatalf("want both keys named, got %+v", result)
	}
}

func TestACatalogThatMovedIsComparedOnShape(t *testing.T) {
	first := list(item("u1", "A"), item("u2", "B"))
	second := list(item("u1", "A"), item("u3", "C"))
	goAnswer := list(item("u1", "A"), item("u3", "C"), item("u4", "D"))
	result := Classify(query, text(first), text(second), text(goAnswer))
	if result.Verdict != SameShape || len(result.Varies) == 0 {
		t.Fatalf("want same-shape with what varied, got %+v", result)
	}
}

func TestAMovedCatalogStillComparesTheItemsInBothInFull(t *testing.T) {
	first := list(item("u1", "A"), item("u2", "B"))
	second := list(item("u1", "A"), item("u3", "C"))
	result := Classify(query, text(first), text(second), text(list(item("u1", "CHANGED"), item("u3", "C"))))
	if result.Verdict != Different {
		t.Fatalf("an item in both with a changed value is a difference, got %+v", result)
	}
}

func TestAMovedCatalogStillComparesTheOrderOfTheItemsInBoth(t *testing.T) {
	first := list(item("u1", "A"), item("u2", "B"))
	second := list(item("u1", "A"), item("u2", "B"), item("u9", "Z"))
	result := Classify(query, text(first), text(second), text(list(item("u2", "B"), item("u1", "A"))))
	if result.Verdict != Different || !strings.Contains(strings.Join(result.Details, "\n"), "different order") {
		t.Fatalf("want an order difference, got %+v", result)
	}
}

func TestAMovedCatalogStillComparesTheDateTheServersWorkedOut(t *testing.T) {
	first := list(item("u1", "A"))
	second := list(item("u1", "A"), item("u2", "B"))
	other := strings.Replace(second, "2026-11-23", "2026-11-24", 1)
	result := Classify(query, text(first), text(second), text(other))
	if result.Verdict != Different {
		t.Fatalf("want different, got %+v", result)
	}
}

func TestAMovedCatalogStillComparesTheFieldsTheItemsUse(t *testing.T) {
	first := list(item("u1", "A"))
	second := list(item("u1", "A"), item("u2", "B"))
	extra := list(`{"title":"A","status":"Released","url":"u1","rating":5}`, item("u3", "C"))
	result := Classify(query, text(first), text(second), text(extra))
	if result.Verdict != Different {
		t.Fatalf("want different, got %+v", result)
	}
}

func TestErrorsAreComparedAsExactText(t *testing.T) {
	same := Answer{Text: "x needs its one text argument (at most 300 characters)", IsError: true}
	if got := Classify(query, same, same, same).Verdict; got != Identical {
		t.Fatalf("want identical, got %s", got)
	}
	other := Answer{Text: "different", IsError: true}
	result := Classify(query, same, same, other)
	if result.Verdict != Different || !strings.Contains(result.Details[0], "error:") {
		t.Fatalf("want different, got %+v", result)
	}
}

func TestAProtocolErrorIsComparedToo(t *testing.T) {
	a := Answer{Protocol: "protocol error -32602: cannot handle that request"}
	if got := Classify(query, a, a, a).Verdict; got != Identical {
		t.Fatalf("want identical, got %s", got)
	}
	if got := Classify(query, a, a, Answer{Text: "{}"}).Verdict; got != Different {
		t.Fatalf("want different, got %s", got)
	}
}

func TestSuccessAgainstErrorIsDifferent(t *testing.T) {
	ok, bad := text(list(item("u1", "A"))), Answer{Text: "boom", IsError: true}
	if got := Classify(query, ok, ok, bad).Verdict; got != Different {
		t.Fatalf("want different, got %s", got)
	}
}

func TestTextThatIsNotJSONIsComparedAsText(t *testing.T) {
	if got := Classify(query, text("plain"), text("plain"), text("plain")).Verdict; got != Identical {
		t.Fatalf("want identical, got %s", got)
	}
	if got := Classify(query, text("plain"), text("plain"), text("other")).Verdict; got != Different {
		t.Fatalf("want different, got %s", got)
	}
}

func TestManyDifferencesAreCapped(t *testing.T) {
	var items, changed []string
	for i := 0; i < 20; i++ {
		id := string(rune('a' + i))
		items, changed = append(items, item(id, "A")), append(changed, item(id, "B"))
	}
	result := Classify(query, text(list(items...)), text(list(items...)), text(list(changed...)))
	if len(result.Details) != maxReported+1 || !strings.Contains(result.Details[maxReported], "more") {
		t.Fatalf("want %d details and a count of the rest, got %v", maxReported, result.Details)
	}
}

func TestReportFailsOnAnyDifferenceAndNamesWhatVaried(t *testing.T) {
	good := Report{ToolsMatch: true, Results: []Result{{Query: query, Verdict: Identical},
		{Query: Query{Name: "moved"}, Verdict: SameShape, Varies: []string{".released: 2 items against 3"}}}}
	if good.Failed() {
		t.Fatal("identical and same-shape results do not fail")
	}
	var out strings.Builder
	good.Write(&out)
	for _, want := range []string{"tools/list: identical", "2 queries: 1 identical, 1 same-shape, 0 different",
		"changed between the two python runs for 1 queries", "moved"} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("the report lacks %q:\n%s", want, out.String())
		}
	}
	bad := Report{ToolsMatch: true, Results: []Result{{Query: query, Verdict: Different}}}
	toolsBad := Report{ToolsMatch: false}
	if !bad.Failed() || !toolsBad.Failed() {
		t.Fatal("a different answer or a different tool listing fails")
	}
}
