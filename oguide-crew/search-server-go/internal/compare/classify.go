package compare

import (
	"encoding/json"
	"fmt"
	"reflect"
	"sort"
)

// Verdict says how the Go server's answer compares with the Python server's.
type Verdict string

// The verdicts, from best to worst.
const (
	// Identical: the same text result, key for key.
	Identical Verdict = "identical"
	// SameShape: the catalog itself changed between two runs of the Python server, so only the shape
	// and the fields that stay stable are compared, and they match.
	SameShape Verdict = "same-shape"
	// Different: the two servers disagree where the catalog gave them the same input.
	Different Verdict = "DIFFERENT"
)

const (
	maxReported = 8
	keyURL      = "url"
)

// Result is the comparison of one query.
type Result struct {
	Query   Query
	Verdict Verdict
	// Varies is what differed between the two Python runs: the catalog, not the servers.
	Varies []string
	// Details are the differences a Different verdict found.
	Details []string
}

// Classify compares the Go answer with the Python answer, using a second Python answer to tell a
// catalog that changed from a server that differs.
func Classify(query Query, python, again, goAnswer Answer) Result {
	result := Result{Query: query}
	if python.Protocol != "" || goAnswer.Protocol != "" || python.IsError || goAnswer.IsError {
		return plainResult(result, python, goAnswer)
	}
	pythonJSON, goJSON, ok := decodePair(python.Text, goAnswer.Text)
	if !ok {
		return plainResult(result, python, goAnswer)
	}
	var againJSON any
	_ = json.Unmarshal([]byte(again.Text), &againJSON)
	result.Varies = diff("", pythonJSON, againJSON, false)
	if len(result.Varies) == 0 {
		return finish(result, diff("", pythonJSON, goJSON, false), Identical)
	}
	return finish(result, diff("", pythonJSON, goJSON, true), SameShape)
}

func finish(result Result, details []string, ok Verdict) Result {
	if len(details) == 0 {
		result.Verdict = ok
		return result
	}
	result.Verdict, result.Details = Different, limit(details)
	return result
}

// plainResult compares answers that are errors or not JSON as the exact text.
func plainResult(result Result, python, goAnswer Answer) Result {
	if python == goAnswer {
		result.Verdict = Identical
		return result
	}
	result.Verdict = Different
	result.Details = []string{fmt.Sprintf("python %s, go %s", describe(python), describe(goAnswer))}
	return result
}

func describe(a Answer) string {
	switch {
	case a.Protocol != "":
		return "protocol error: " + a.Protocol
	case a.IsError:
		return "error: " + a.Text
	default:
		return "text: " + a.Text
	}
}

func decodePair(first, second string) (any, any, bool) {
	var a, b any
	if json.Unmarshal([]byte(first), &a) != nil || json.Unmarshal([]byte(second), &b) != nil {
		return nil, nil, false
	}
	return a, b, true
}

func limit(details []string) []string {
	if len(details) > maxReported {
		return append(details[:maxReported:maxReported], fmt.Sprintf("... and %d more", len(details)-maxReported))
	}
	return details
}

// diff lists where two decoded results differ. With shapeOnly, the values of items that are not in
// both results, and the scalars that name a catalog's content, are not compared; the keys, the
// types, and the items in both results are.
func diff(path string, a, b any, shapeOnly bool) []string {
	switch left := a.(type) {
	case map[string]any:
		right, ok := b.(map[string]any)
		if !ok {
			return []string{path + ": a different kind of value"}
		}
		return diffObjects(path, left, right, shapeOnly)
	case []any:
		right, ok := b.([]any)
		if !ok {
			return []string{path + ": a different kind of value"}
		}
		return diffLists(path, left, right, shapeOnly)
	default:
		return diffScalars(path, a, b, shapeOnly)
	}
}

func diffScalars(path string, a, b any, shapeOnly bool) []string {
	if reflect.TypeOf(a) != reflect.TypeOf(b) {
		return []string{fmt.Sprintf("%s: %T against %T", path, a, b)}
	}
	if shapeOnly && !stableField(path) {
		return nil
	}
	if !reflect.DeepEqual(a, b) {
		return []string{fmt.Sprintf("%s: %v against %v", path, a, b)}
	}
	return nil
}

// stableField is true for the scalars that must match even when the catalog changed: the date the
// servers worked out and where it came from, and each item's own values.
func stableField(path string) bool {
	return path == ".today" || path == ".dateSource" || path == ".repeat"
}

func diffObjects(path string, a, b map[string]any, shapeOnly bool) []string {
	var out []string
	for _, key := range sortedKeys(a) {
		other, found := b[key]
		if !found {
			out = append(out, path+"."+key+": only in the python result")
			continue
		}
		out = append(out, diff(path+"."+key, a[key], other, shapeOnly)...)
	}
	for _, key := range sortedKeys(b) {
		if _, found := a[key]; !found {
			out = append(out, path+"."+key+": only in the go result")
		}
	}
	return out
}

func sortedKeys(object map[string]any) []string {
	keys := make([]string, 0, len(object))
	for key := range object {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func diffLists(path string, a, b []any, shapeOnly bool) []string {
	if !shapeOnly {
		return diffInOrder(path, a, b)
	}
	return diffShapes(path, a, b)
}

func diffInOrder(path string, a, b []any) []string {
	var out []string
	if len(a) != len(b) {
		out = append(out, fmt.Sprintf("%s: %d items against %d", path, len(a), len(b)))
	}
	for i := 0; i < len(a) && i < len(b); i++ {
		out = append(out, diff(fmt.Sprintf("%s[%d]", path, i), a[i], b[i], false)...)
	}
	return out
}

// identity names a list entry: an item by its url, an author group by its author.
func identity(entry any) string {
	fields, _ := entry.(map[string]any)
	for _, key := range []string{keyURL, "author"} {
		if text, ok := fields[key].(string); ok {
			return text
		}
	}
	return ""
}

// diffShapes compares two lists whose catalog moved: the entries in both are compared in full and
// in the same relative order; the entries in only one only have to look like the others.
func diffShapes(path string, a, b []any) []string {
	var out []string
	inB := map[string]any{}
	for _, entry := range b {
		inB[identity(entry)] = entry
	}
	var orderA, orderB []string
	for _, entry := range a {
		name := identity(entry)
		if other, both := inB[name]; both && name != "" {
			orderA = append(orderA, name)
			out = append(out, diff(path+"["+name+"]", entry, other, false)...)
		}
	}
	for _, entry := range b {
		if name := identity(entry); name != "" && inA(a, name) {
			orderB = append(orderB, name)
		}
	}
	if !reflect.DeepEqual(orderA, orderB) {
		out = append(out, path+": the items in both are in a different order")
	}
	return append(out, diffKeySets(path, a, b)...)
}

func inA(list []any, name string) bool {
	for _, entry := range list {
		if identity(entry) == name {
			return true
		}
	}
	return false
}

// diffKeySets checks that the objects of each list use the same field names.
func diffKeySets(path string, a, b []any) []string {
	left, right := fieldNames(a), fieldNames(b)
	if len(left) == 0 || len(right) == 0 || reflect.DeepEqual(left, right) {
		return nil
	}
	return []string{fmt.Sprintf("%s: the items use the fields %v against %v", path, left, right)}
}

func fieldNames(list []any) []string {
	seen := map[string]bool{}
	for _, entry := range list {
		if fields, ok := entry.(map[string]any); ok {
			for key := range fields {
				seen[key] = true
			}
		}
	}
	names := make([]string, 0, len(seen))
	for key := range seen {
		names = append(names, key)
	}
	sort.Strings(names)
	return names
}
