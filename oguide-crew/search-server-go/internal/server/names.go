package server

import (
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"
)

const minItemsForNamedAuthor = 3

var (
	wordPattern  = regexp.MustCompile(`[\p{L}\p{N}_]+`)
	nameSuffixes = map[string]bool{"jr": true, "sr": true, "ii": true, "iii": true, "iv": true}
)

type tokenSet map[string]struct{}

// withoutAccents lowers the text and removes the marks that decompose off its letters.
func withoutAccents(text string) string {
	var plain strings.Builder
	for _, r := range norm.NFKD.String(text) {
		if norm.NFD.PropertiesString(string(r)).CCC() == 0 {
			plain.WriteRune(r)
		}
	}
	return strings.ToLower(plain.String())
}

// nameTokens are the words of a person's name: lower case, accents removed, initials and
// suffixes dropped. "Neal E. Ford", "ford, neal" and "NEAL FORD" all give {neal, ford};
// "Neil Ford" does not. A value that is not text has no words.
func nameTokens(name any) tokenSet {
	tokens := tokenSet{}
	text, ok := name.(string)
	if !ok {
		return tokens
	}
	for _, word := range wordPattern.FindAllString(withoutAccents(text), -1) {
		if utf8.RuneCountInString(word) > 1 && !nameSuffixes[word] {
			tokens[word] = struct{}{}
		}
	}
	return tokens
}

// subsetOf is true when every word of small is in large.
func (small tokenSet) subsetOf(large tokenSet) bool {
	for word := range small {
		if _, found := large[word]; !found {
			return false
		}
	}
	return true
}

// minus counts the words of this set that are not in other.
func (large tokenSet) minus(other tokenSet) int {
	count := 0
	for word := range large {
		if _, found := other[word]; !found {
			count++
		}
	}
	return count
}

// key is the set as one comparable string.
func (small tokenSet) key() string {
	words := make([]string, 0, len(small))
	for word := range small {
		words = append(words, word)
	}
	sort.Strings(words)
	return strings.Join(words, "\x00")
}

// hasAuthor is true when one of the item's authors has every word of the wanted name.
func hasAuthor(item Item, wanted tokenSet) bool {
	for _, author := range item.authors() {
		if wanted.subsetOf(nameTokens(author)) {
			return true
		}
	}
	return false
}

// publisherKeys are the name keys of every publisher the items list, so a publisher's name is
// not taken for a person's.
func publisherKeys(items []Item) map[string]bool {
	keys := map[string]bool{}
	for _, item := range items {
		for _, publisher := range asList(item.get("publisher_names")) {
			keys[nameTokens(publisher).key()] = true
		}
	}
	return keys
}

// authorCounts counts, per author string in first-seen order, the items that list a person
// whose full name is most of the topic: the name is in the topic with at most one other word.
func authorCounts(topic string, items []Item) ([]string, map[string]int) {
	words := nameTokens(topic)
	publishers := publisherKeys(items)
	counts, order := map[string]int{}, []string{}
	for _, item := range items {
		for _, author := range item.authors() {
			text, _ := author.(string)
			tokens := nameTokens(author)
			isPerson := len(tokens) >= 2 && !publishers[tokens.key()]
			if !isPerson || !tokens.subsetOf(words) || words.minus(tokens) > 1 {
				continue
			}
			if _, seen := counts[text]; !seen {
				order = append(order, text)
			}
			counts[text]++
		}
	}
	return order, counts
}

// namedAuthor is a person whose full name is most of the topic, when at least three items list
// that person. A publisher's name is not a person's.
func namedAuthor(topic string, items []Item) string {
	order, counts := authorCounts(topic, items)
	best, bestCount := "", 0
	for _, author := range order {
		if counts[author] > bestCount {
			best, bestCount = author, counts[author]
		}
	}
	if bestCount >= minItemsForNamedAuthor {
		return best
	}
	return ""
}

// matchingNames are the author strings, exactly as the catalog lists them, that match the
// wanted name, in sorted order.
func matchingNames(items []Item, wanted tokenSet) []string {
	found := map[string]bool{}
	for _, item := range items {
		for _, author := range item.authors() {
			if text, ok := author.(string); ok && wanted.subsetOf(nameTokens(text)) {
				found[text] = true
			}
		}
	}
	names := make([]string, 0, len(found))
	for text := range found {
		names = append(names, text)
	}
	sort.Strings(names)
	return names
}

func authorPointer(topic, author string) *obj {
	return newObj().set(keyMessage, "'"+topic+"' names an author, "+author+". Use find_by_author with the name "+
		"to see the author's work; if you meant the subject, search with more specific keywords.")
}
