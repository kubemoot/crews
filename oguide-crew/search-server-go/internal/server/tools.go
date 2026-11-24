package server

import (
	"strconv"
	"strings"
)

const (
	itemsPerSearch = 25
	itemsPerBooks  = 50
	itemsPerTitle  = 10
	keyMessage     = "message"
	keyQuery       = "query"
	keyNItems      = "n_items"
	keySortOrder   = "sort_order"

	keyReleasedBooks   = "released_books"
	keyScheduledBooks  = "scheduled_books"
	keyReleasedOther   = "released_other_formats"
	keyScheduledOther  = "scheduled_other_formats"
	keyUpcomingEvents  = "upcoming_live_events"
	keyReleased        = "released"
	keyScheduled       = "scheduled"
	contentTypesKey    = "content_types"
	authorFilterKey    = "author_filter"
	orderByKey         = "order_by"
	defaultListLimit   = 5
	needFullNameAnswer = "Give the author's full name (first and last name)."
)

var (
	otherTypes = []string{"videos", "courses", "interactive", "audiobooks", "certifications"}
	bookTypes  = []string{"books"}
	liveTypes  = []string{"live-events"}
)

// handler runs one search tool for the argument the model gave and today's date.
type handler func(c Catalog, value, today string) (*obj, error)

var handlers = map[string]handler{
	"find_released":    findReleased,
	"find_scheduled":   findScheduled,
	"find_by_author":   findByAuthor,
	"find_title":       findTitle,
	"find_live_events": findLiveEvents,
}

// fetch runs one catalog search and checks the items.
func fetch(c Catalog, arguments map[string]any) ([]Item, error) {
	raw, err := c.Search(arguments)
	if err != nil {
		return nil, err
	}
	return parseItems(raw)
}

// rangedSearch is a catalog search limited to items released up to today, or scheduled from
// today on.
func rangedSearch(c Catalog, arguments map[string]any, today string, released bool) ([]Item, error) {
	full := map[string]any{}
	for key, value := range arguments {
		full[key] = value
	}
	full["date_range"] = releaseRange(today, released)
	return fetch(c, full)
}

func topicSearch(c Catalog, topic, today string, released bool) ([]Item, error) {
	return rangedSearch(c, map[string]any{keyQuery: topic, keyNItems: itemsPerSearch}, today, released)
}

func recorded(items []Item) []Item {
	return filterItems(items, func(i Item) bool { return !i.isLive() })
}

func findReleased(c Catalog, topic, today string) (*obj, error) {
	found, err := topicSearch(c, topic, today, true)
	if err != nil {
		return nil, err
	}
	items := recorded(found)
	if author := namedAuthor(topic, items); author != "" {
		return authorPointer(topic, author), nil
	}
	released, _ := ordered(items, today)
	return newObj().set(keyReleased, released), nil
}

// findScheduled is the announced recorded content; live events are find_live_events' business.
func findScheduled(c Catalog, topic, today string) (*obj, error) {
	found, err := topicSearch(c, topic, today, false)
	if err != nil {
		return nil, err
	}
	items := recorded(found)
	if author := namedAuthor(topic, items); author != "" {
		return authorPointer(topic, author), nil
	}
	_, scheduled := ordered(items, today)
	return newObj().set(keyScheduled, scheduled), nil
}

// authorGroup is one format group of an author's raw items, released and scheduled. A nil list
// is a search that failed; the notes name a search that failed or that hit its limit.
type authorGroup struct {
	released, scheduled []Item
	failedReleased      bool
	failedScheduled     bool
	notes               []string
}

func (g authorGroup) allFailed() bool { return g.failedReleased && g.failedScheduled }

func searchAuthorGroup(c Catalog, name, label string, types []string, limit int, today string) (authorGroup, error) {
	shared := map[string]any{keyQuery: "*", authorFilterKey: []string{name}, contentTypesKey: types,
		keyNItems: limit, orderByKey: "date_published"}
	var group authorGroup
	for _, released := range []bool{true, false} {
		status, order := "released", "desc"
		if !released {
			status, order = "scheduled", "asc"
		}
		arguments := map[string]any{keySortOrder: order}
		for key, value := range shared {
			arguments[key] = value
		}
		items, err := rangedSearch(c, arguments, today, released)
		if err != nil {
			if _, isCatalog := asCatalogError(err); !isCatalog {
				return group, err
			}
			group.fail(released)
			group.notes = append(group.notes, "the "+status+" "+label+" could not be searched ("+err.Error()+")")
			continue
		}
		group.keep(released, items)
		if len(items) >= limit {
			group.notes = append(group.notes, "the "+status+" "+label+" reached the limit of "+strconv.Itoa(limit)+
				", so older or later ones may be missing")
		}
	}
	return group, nil
}

func (g *authorGroup) fail(released bool) {
	if released {
		g.failedReleased = true
	} else {
		g.failedScheduled = true
	}
}

func (g *authorGroup) keep(released bool, items []Item) {
	if released {
		g.released = items
	} else {
		g.scheduled = items
	}
}

// liveSearch is the upcoming live events. The catalog never returns past ones and its
// publication_date is not the session date, so a date range would drop events; the order is the
// soonest session first.
func liveSearch(c Catalog, arguments map[string]any) ([]Item, error) {
	full := map[string]any{}
	for key, value := range arguments {
		full[key] = value
	}
	full[contentTypesKey], full[keyNItems], full[orderByKey], full[keySortOrder] = liveTypes, itemsPerSearch,
		"upcoming_events", "asc"
	return fetch(c, full)
}

// authorLiveEvents are the upcoming live events of the author and notes naming a failed search.
// The list is nil when the search failed.
func authorLiveEvents(c Catalog, name string, wanted tokenSet, today string) ([]Item, bool, []string, error) {
	items, err := liveSearch(c, map[string]any{keyQuery: "*", authorFilterKey: []string{name}})
	if err != nil {
		if _, isCatalog := asCatalogError(err); !isCatalog {
			return nil, false, nil, err
		}
		return nil, false, []string{"the live events could not be searched (" + err.Error() + ")"}, nil
	}
	scheduled := filterItems(items, func(i Item) bool {
		return hasAuthor(i, wanted) && i.status(today) == statusScheduled
	})
	if len(items) >= itemsPerSearch {
		return scheduled, true, []string{"the live events reached the limit of " + strconv.Itoa(itemsPerSearch) +
			", so later ones may be missing"}, nil
	}
	return scheduled, true, nil, nil
}

// authorSearches are the searches behind one find_by_author.
type authorSearches struct {
	books, other authorGroup
	live         []Item
	liveOK       bool
	liveNotes    []string
}

func runAuthorSearches(c Catalog, name string, wanted tokenSet, today string) (authorSearches, error) {
	var out authorSearches
	var err error
	if out.books, err = searchAuthorGroup(c, name, "books", bookTypes, itemsPerBooks, today); err != nil {
		return out, err
	}
	if out.other, err = searchAuthorGroup(c, name, "other formats", otherTypes, itemsPerSearch, today); err != nil {
		return out, err
	}
	out.live, out.liveOK, out.liveNotes, err = authorLiveEvents(c, name, wanted, today)
	return out, err
}

// findByAuthor is the author's books and the newest items of the other formats, each group
// searched on its own. A failed or capped search is named in the message; the tool fails only
// when every search failed.
func findByAuthor(c Catalog, name, today string) (*obj, error) {
	wanted := nameTokens(name)
	if len(wanted) == 0 {
		return newObj().set(keyMessage, needFullNameAnswer), nil
	}
	found, err := runAuthorSearches(c, name, wanted, today)
	if err != nil {
		return nil, err
	}
	if !found.liveOK && found.books.allFailed() && found.other.allFailed() {
		return nil, catalogErr("every author search failed")
	}
	mine := func(i Item) bool { return hasAuthor(i, wanted) }
	books := filterItems(mergeUnique(found.books.released, found.books.scheduled), mine)
	inBooks := map[string]bool{}
	for _, item := range books {
		inBooks[item.key()] = true
	}
	other := filterItems(mergeUnique(found.other.released, found.other.scheduled),
		func(i Item) bool { return mine(i) && !inBooks[i.key()] })
	notes := append(append(append([]string{}, found.books.notes...), found.other.notes...), found.liveNotes...)
	names := matchingNames(append(append(append([]Item{}, books...), other...), found.live...), wanted)
	payload := authorLists(books, other, found.live, today)
	if len(names) > 1 {
		payload = splitByAuthor(names, books, other, found.live, today)
	}
	if len(notes) > 0 {
		text, _ := payload.get(keyMessage).(string)
		payload.set(keyMessage, strings.TrimSpace(text+" Part of this list may be missing: "+strings.Join(notes, "; ")+"."))
	}
	return payload, nil
}

func authorLists(books, other, live []Item, today string) *obj {
	releasedBooks, scheduledBooks := ordered(books, today)
	releasedOther, scheduledOther := ordered(other, today)
	_, upcoming := ordered(live, today)
	return newObj().set(keyReleasedBooks, releasedBooks).set(keyScheduledBooks, scheduledBooks).
		set(keyReleasedOther, releasedOther).set(keyScheduledOther, scheduledOther).set(keyUpcomingEvents, upcoming)
}

// splitByAuthor is one group per author string; an item is in the group of each matching string
// it lists.
func splitByAuthor(names []string, books, other, live []Item, today string) *obj {
	groups := make([]any, 0, len(names))
	for _, name := range names {
		own := func(items []Item) []Item {
			return filterItems(items, func(i Item) bool { return listsAuthor(i, name) })
		}
		ownBooks, ownOther, ownLive := own(books), own(other), own(live)
		lists := authorLists(ownBooks, ownOther, ownLive, today)
		everything := append(append(append([]Item{}, ownBooks...), ownOther...), ownLive...)
		group := newObj().set("author", name).set("item_counts", countsOf(lists)).
			set("topics", topicsOf(everything, defaultListLimit)).
			set("formats", common(everything, "marketing_type", defaultListLimit)).
			set("publishers", common(everything, "publisher_names", defaultListLimit))
		for _, key := range lists.keys {
			group.set(key, lists.get(key))
		}
		groups = append(groups, group)
	}
	quoted := make([]string, 0, len(names))
	for _, name := range names {
		quoted = append(quoted, `"`+name+`"`)
	}
	return newObj().set(keyMessage, "The name matches "+strconv.Itoa(len(names))+" different author entries in the "+
		"catalog: "+strings.Join(quoted, ", ")+". They may be different people or one person listed two ways. "+
		"Each group below is one entry, not merged. Ask which one is meant or pick by topic.").set("authors", groups)
}

func listsAuthor(item Item, name string) bool {
	for _, author := range item.authors() {
		if text, ok := author.(string); ok && text == name {
			return true
		}
	}
	return false
}

func countsOf(lists *obj) *obj {
	counts := newObj()
	for _, key := range lists.keys {
		counts.set(key, listLen(lists.get(key)))
	}
	return counts
}

// findTitle is a named item whatever its date, best match first.
func findTitle(c Catalog, title, today string) (*obj, error) {
	items, err := fetch(c, map[string]any{keyQuery: title, keyNItems: itemsPerTitle})
	if err != nil {
		return nil, err
	}
	ranked := append([]Item{}, items...)
	sortByScore(ranked)
	entries := make([]Entry, 0, len(ranked))
	for _, item := range ranked {
		entries = append(entries, shape(item, today))
	}
	return newObj().set("items", entries), nil
}

func findLiveEvents(c Catalog, topic, today string) (*obj, error) {
	items, err := liveSearch(c, map[string]any{keyQuery: topic})
	if err != nil {
		return nil, err
	}
	if author := namedAuthor(topic, items); author != "" {
		return authorPointer(topic, author), nil
	}
	_, scheduled := ordered(items, today)
	return newObj().set(keyScheduled, scheduled), nil
}
