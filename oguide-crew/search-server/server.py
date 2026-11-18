"""O'guide search server: fixed O'Reilly catalog searches as an MCP server over stdio.

The model names a topic or an author. This server builds every search argument itself (the
date filters, the item count, the ordering), labels each item Released or Scheduled from its
own date against today's date, and sorts the results. It speaks MCP on stdin and stdout; the
operator's bridge connects it to the gateway.

Configuration comes from the environment:
  OREILLY_GATEWAY_URL        the crew's MCP gateway, which holds the O'Reilly key and forwards the search
  OREILLY_DEFAULT_TIMEZONE   IANA time zone whose date is "today" when a request carries none (default UTC)
  OREILLY_PER_PERSON         "true" when each person's own O'Reilly access is on: every tool description gets
                             OREILLY_ACCESS_NOTE appended, and the asker's conversationId and principalId, which
                             the gateway relays in params._meta, are passed back on each gateway call so the
                             gateway can use that person's own token for it (never set otherwise)
  OREILLY_ACCESS_NOTE        the sentence appended to every tool description with OREILLY_PER_PERSON
  OREILLY_EXPERT             "true" when the gateway's O'Reilly server is the Expert MCP: this server then also
                             offers ask_experts and get_citation (default: off)

The server holds no key. It calls the raw search tool through the gateway's tool endpoint
(POST <gateway>/tools/search_oreilly_content/call), as agents do.

"Today" is the requester's date, never the model's. A tools/call may carry it in params._meta:
  "requestDate"    an ISO date (YYYY-MM-DD); used as given
  "localDateTime"  the requester's local date and time (ISO 8601, no offset); its date is used
  "timeZone"       an IANA time zone name; today is the date now in that zone
requestDate wins over localDateTime, which wins over timeZone, which wins over the default zone.
A value that is missing or malformed is ignored. Every result says which date and which source it used.
"""
import datetime
import http.client
import json
import os
import re
import sys
import time
import unicodedata
import urllib.error
import urllib.request
import zoneinfo

SERVER_NAME = "oguide-search"
PROTOCOL_VERSION = "2025-03-26"
N_ITEMS = 25
N_BOOKS = 50
BOOK_TYPES = ["books"]
OTHER_TYPES = ["videos", "courses", "interactive", "audiobooks", "certifications"]
LIVE_TYPES = ["live-events"]
TIMEOUT_SECONDS = 15
MAX_REPLY_BYTES = 5_000_000
MAX_UPSTREAM_MESSAGE_CHARS = 160
TITLE_ITEMS = 10
REPEAT_SECONDS = 20
MAX_REMEMBERED_CALLS = 256
NAME_SUFFIXES = frozenset({"jr", "sr", "ii", "iii", "iv"})
MIN_ITEMS_FOR_NAMED_AUTHOR = 3
MAX_ARGUMENT_CHARS = 300
SEARCH_TOOL = "search_oreilly_content"
ASK_TOOL = "ask_oreilly_experts"
CITATION_TOOL = "get_oreilly_citation"
MAX_QUESTION_CHARS = 1000
RELAYED_META_KEYS = ("conversationId", "principalId")
MAX_RELAYED_CHARS = 256
NO_EXPERT_ACCESS = ("This O'Reilly account does not include Expert Intelligence (the Expert MCP entitlement), "
                    "so the Expert tools are refused. Nothing was retrieved; say so and do not answer from memory.")

TOOLS = [
    {
        "name": "find_released",
        "description": "Search the O'Reilly catalog for released books, videos, courses and other recorded "
                       "content on a topic (not live events: find_live_events has those). Every item is "
                       "labelled Released and the list is newest first. For one person's work use find_by_author.",
        "argument": "topic",
        "argument_description": "Descriptive keywords for the topic, not a question",
    },
    {
        "name": "find_scheduled",
        "description": "Search the O'Reilly catalog for books, videos and courses on a topic that are announced "
                       "but not yet released. Every item is labelled Scheduled and the list is soonest first.",
        "argument": "topic",
        "argument_description": "Descriptive keywords for the topic, not a question",
    },
    {
        "name": "find_by_author",
        "description": "Find the work of one author in the O'Reilly catalog, books and live events included. "
                       "Books (up to 50 per status) come first as released_books newest first and "
                       "scheduled_books soonest first; other recorded formats (videos, courses and more) are "
                       "only the newest 25 per status; upcoming_live_events lists the author's live events "
                       "and live courses with every session date, soonest first. "
                       "A message says when a list may be missing items, or when the name matches more than "
                       "one author entry (then authors holds one separate group per entry, each with author, "
                       "item_counts, topics, formats, publishers and its own lists). Durations are text such as "
                       "10 h 31 min. "
                       "Every item is labelled Released or Scheduled.",
        "argument": "name",
        "argument_description": "The author's full name",
    },
    {
        "name": "find_title",
        "description": "Look up one named book, video or course in the O'Reilly catalog, whether it is released or "
                       "scheduled. Items are ordered by how well they match the title; each is labelled Released "
                       "or Scheduled.",
        "argument": "title",
        "argument_description": "The title, or the words of it you know",
    },
    {
        "name": "find_live_events",
        "description": "Search the O'Reilly catalog for upcoming live events and live courses on a topic, with "
                       "their session dates, soonest first. Past events are never listed. For one person's "
                       "live events use find_by_author.",
        "argument": "topic",
        "argument_description": "Descriptive keywords for the topic, not a question",
    },
]


EXPERT_TOOLS = [
    {
        "name": "ask_experts",
        "upstream": ASK_TOOL,
        "description": "Ask O'Reilly's expert-authored library a specific technical question and get back "
                       "grounded, citable snippets (each with product_id, offset, the book or video title, "
                       "authors, publication date, chapter, a snippet preview and a learning.oreilly.com link). "
                       "It returns passages to cite, not a list of titles; every claim made from them must "
                       "name the item and link it returned. Results reflect the asking account's O'Reilly "
                       "access. Use find_released or find_by_author to browse the catalog instead.",
        "properties": {
            "question": {"type": "string", "description": "The technical question, in plain words"},
            "context": {"type": "string", "description": "What the asker is working on or trying to achieve"},
            "author": {"type": "string", "description": "Restrict results to works by this author"},
            "published_after": {"type": "string",
                                "description": "Only results published on or after this date (YYYY-MM-DD)"},
            "published_before": {"type": "string",
                                 "description": "Only results published on or before this date (YYYY-MM-DD)"},
            "max_results": {"type": "integer", "minimum": 1, "maximum": 20,
                            "description": "Most results to return, 1 to 20 (default 10)"},
            "within_product_id": {"type": "string",
                                  "description": "Restrict the search to one item, by a returned product_id"},
        },
        "required": ["question"],
        "text": ["question", "context", "author", "published_after", "published_before", "within_product_id"],
    },
    {
        "name": "get_citation",
        "upstream": CITATION_TOOL,
        "description": "Retrieve the full, citable source text of one snippet that ask_experts returned. "
                       "Only a product_id and offset from an ask_experts result in this conversation work; "
                       "any other pair is refused.",
        "properties": {
            "product_id": {"type": "string",
                           "description": "The product_id of the snippet, from an ask_experts result"},
            "offset": {"type": "integer", "minimum": 0,
                       "description": "The offset of the snippet, from the same result"},
        },
        "required": ["product_id", "offset"],
        "text": ["product_id"],
    },
]
EXPERT_BY_NAME = {t["name"]: t for t in EXPERT_TOOLS}


class CatalogError(Exception):
    """The O'Reilly catalog could not be searched. The message is written for the model to read."""


class EntitlementError(CatalogError):
    """O'Reilly refused the account: it does not carry the Expert MCP entitlement (HTTP 403)."""


def is_forbidden(text):
    """True when upstream text is O'Reilly's 403 (a refused account), however the gateway wrapped it."""
    return bool(re.search(r"HTTP 403|xmcp|\bforbidden\b|refused this call", str(text), re.IGNORECASE))


def utc_now():
    return datetime.datetime.now(datetime.UTC)


def zone_named(name):
    """The IANA zone with this name, or None when the name is missing or unknown."""
    if not isinstance(name, str) or not name.strip():
        return None
    try:
        return zoneinfo.ZoneInfo(name.strip())
    except (zoneinfo.ZoneInfoNotFoundError, ValueError, OSError):
        return None


def date_named(text):
    """The ISO date (YYYY-MM-DD) in this text, or None when it is missing or malformed."""
    if not isinstance(text, str):
        return None
    text = text.strip()
    try:
        return datetime.date.fromisoformat(text) if len(text) == 10 else None
    except ValueError:
        return None


def local_date_of(text):
    """The date of an ISO 8601 date-time (the requester's local clock), or None when it is missing or malformed."""
    if not isinstance(text, str) or len(text.strip()) < 11:
        return None
    try:
        return datetime.datetime.fromisoformat(text.strip()).date()
    except ValueError:
        return None


def resolve_today(meta, default_zone, now):
    """The requester's date and where it came from: requestDate, localDateTime, timeZone, then the default zone."""
    meta = meta if isinstance(meta, dict) else {}
    given = date_named(meta.get("requestDate"))
    if given:
        return given, "the request date"
    local = local_date_of(meta.get("localDateTime"))
    if local:
        return local, "the request local time"
    zone = zone_named(meta.get("timeZone"))
    if zone:
        return now.astimezone(zone).date(), f"the request time zone {zone.key}"
    fallback = zone_named(default_zone)
    if fallback:
        return now.astimezone(fallback).date(), f"the default time zone {fallback.key}"
    return now.astimezone(datetime.UTC).date(), "the default time zone UTC"


def release_range(today, released):
    """The date filter the catalog applies: items up to today, or items from today on."""
    day = today.isoformat()
    if released:
        return {"original_input": "released up to today", "normalized_description": f"released up to {day}",
                "end_date": day, "confidence": 1}
    return {"original_input": "scheduled from today", "normalized_description": f"scheduled from {day}",
            "start_date": day, "confidence": 1}


def sessions_from(item, today):
    """The live event session dates on or after today."""
    day = today.isoformat()
    return sorted(d for d in (item.get("live_event_start_dates") or []) if d >= day)


def status_of(item, today):
    """Scheduled when the item's own date is after today (a live event: has a session from today on)."""
    if item.get("live_event_start_dates"):
        return "Scheduled" if sessions_from(item, today) else "Released"
    published = (item.get("publication_date") or "")[:10]
    return "Scheduled" if published and published > today.isoformat() else "Released"


def human_duration(value):
    """The catalog's duration in seconds as "10 h 31 min"; any other value is returned unchanged."""
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0:
        return value
    if value < 60:
        return f"{int(value)} s"
    minutes = int(value / 60 + 0.5)
    hours, minutes = divmod(minutes, 60)
    if hours and minutes:
        return f"{hours} h {minutes} min"
    return f"{hours} h" if hours else f"{minutes} min"


def shape(item, today):
    """One result item: the catalog's own values plus the status label."""
    out = {
        "title": item.get("title"),
        "authors": item.get("authors") or [],
        "format": item.get("marketing_type") or item.get("display_format"),
        "publication_date": item.get("publication_date") or "",
    }
    for field in ("live_event_start_dates", "page_count"):
        if item.get(field):
            out[field] = item[field]
    if item.get("duration"):
        out["duration"] = human_duration(item["duration"])
    out["status"] = status_of(item, today)
    out["url"] = item.get("url")
    return out


def sort_key(entry, today):
    """The date a scheduled item sorts by: its next session, else its publication date."""
    return (sessions_from(entry, today) or [entry.get("publication_date") or ""])[0]


def ordered(items, today):
    shaped = [shape(i, today) for i in items]
    released = sorted((e for e in shaped if e["status"] == "Released"),
                      key=lambda e: e["publication_date"], reverse=True)
    scheduled = sorted((e for e in shaped if e["status"] == "Scheduled"),
                       key=lambda e: sort_key(e, today))
    return released, scheduled


def name_tokens(name):
    """The words of a person's name: lower case, accents removed, initials and suffixes dropped.

    "Neal E. Ford", "ford, neal" and "NEAL FORD" all give {"neal", "ford"}; "Neil Ford" does not.
    """
    if not isinstance(name, str):
        return set()
    plain = "".join(c for c in unicodedata.normalize("NFKD", name) if not unicodedata.combining(c)).lower()
    return {w for w in re.findall(r"\w+", plain) if len(w) > 1 and w not in NAME_SUFFIXES}


def has_author(item, wanted):
    """True when one of the item's authors has every word of the wanted name."""
    return any(wanted <= name_tokens(a) for a in item.get("authors") or [])


def named_author(topic, items):
    """A person whose full name is most of the topic, when at least three items list that person.

    The name must be in the topic with at most one other word, and a publisher's name is not a person's.
    """
    words = name_tokens(topic)
    publishers = {frozenset(name_tokens(p)) for item in items for p in item.get("publisher_names") or []}
    counts = {}
    for item in items:
        for author in item.get("authors") or []:
            tokens = name_tokens(author)
            is_person = len(tokens) >= 2 and frozenset(tokens) not in publishers
            if is_person and tokens <= words and len(words - tokens) <= 1:
                counts[author] = counts.get(author, 0) + 1
    best = max(counts.items(), key=lambda pair: pair[1], default=None)
    return best[0] if best and best[1] >= MIN_ITEMS_FOR_NAMED_AUTHOR else None


def author_pointer(topic, author):
    return {"message": f"'{topic}' names an author, {author}. Use find_by_author with the name to see the "
                       "author's work; if you meant the subject, search with more specific keywords."}


def item_key(item):
    return item.get("url") or item.get("title")


def merge_unique(first, second):
    """Both lists, an item once by its url."""
    seen, out = set(), []
    for item in first + second:
        key = item_key(item)
        if key not in seen:
            seen.add(key)
            out.append(item)
    return out


class GatewayCatalog:
    """The O'Reilly tools, called through the crew's MCP gateway (which holds the key)."""

    def __init__(self, gateway_url, opener=None, relay=False, context=None):
        self._base = gateway_url.rstrip("/")
        self._open = opener or urllib.request.urlopen
        self._relay = relay
        self._context = context or {}

    def scoped(self, meta):
        """A catalog whose gateway calls carry the asker's conversationId and principalId from meta.

        Without relay (the default) this is the catalog itself and nothing is passed on. Only those two
        keys, only as short text, are ever relayed; the gateway decides what they allow.
        """
        if not self._relay or not isinstance(meta, dict):
            return self
        context = {k: meta[k] for k in RELAYED_META_KEYS
                   if isinstance(meta.get(k), str) and 0 < len(meta[k]) <= MAX_RELAYED_CHARS}
        return GatewayCatalog(self._base, self._open, True, context)

    def call(self, tool, arguments):
        """Run one upstream tool and return the text of its reply."""
        payload = {"arguments": arguments}
        if self._context:
            payload["_meta"] = self._context
        body = json.dumps(payload).encode()
        request = urllib.request.Request(f"{self._base}/tools/{tool}/call", data=body, method="POST",
                                         headers={"Content-Type": "application/json"})
        try:
            with self._open(request, timeout=TIMEOUT_SECONDS) as response:
                raw = response.read(MAX_REPLY_BYTES + 1)
        except urllib.error.HTTPError as err:
            code = err.code
            err.close()
            if code == 403:
                raise EntitlementError(NO_EXPERT_ACCESS) from None
            raise CatalogError(f"the gateway answered HTTP {code}") from None
        except (urllib.error.URLError, http.client.HTTPException, OSError, TimeoutError) as err:
            raise CatalogError(f"the gateway is unreachable ({type(err).__name__})") from None
        if len(raw) > MAX_REPLY_BYTES:
            raise CatalogError("the gateway answered with more than this server reads")
        return content_of(raw.decode("utf-8", "replace"))

    def search(self, arguments):
        """Run one catalog search and return its result items as a list of dicts."""
        return items_in(self.call(SEARCH_TOOL, arguments))


def short(text):
    """The first line of an upstream message, bounded, for an error the model can read."""
    return " ".join(str(text).split())[:MAX_UPSTREAM_MESSAGE_CHARS]


def content_of(text):
    """The tool text in a gateway tool reply {"isError": bool, "content": "<tool text>"}."""
    try:
        reply = json.loads(text)
        content, failed = reply["content"], bool(reply.get("isError"))
    except (ValueError, KeyError, TypeError, AttributeError):
        raise CatalogError("the gateway answered in a shape this server does not know") from None
    if failed and is_forbidden(content):
        raise EntitlementError(NO_EXPERT_ACCESS)
    if failed:
        raise CatalogError(f"the gateway said: {short(content)}")
    return content


def items_from(text):
    """The result items in a gateway tool reply."""
    return items_in(content_of(text))


def items_in(content):
    """The result items in the text of a catalog search."""
    try:
        results = json.loads(content)["search_results"]
    except (ValueError, KeyError, TypeError, AttributeError):
        raise CatalogError(f"the catalog did not return results: {short(content)}") from None
    # The catalog answers {urn: item} when it found items and [] when it found none.
    if isinstance(results, dict):
        found = results.values()
    elif isinstance(results, list):
        found = results
    else:
        raise CatalogError(f"the catalog did not return results: {short(content)}")
    return [item for item in found if isinstance(item, dict)]


def ranged_search(catalog, arguments, today, released):
    """A catalog search limited to items released up to today, or scheduled from today on."""
    return catalog.search({**arguments, "date_range": release_range(today, released)})


def topic_search(catalog, topic, today, released):
    return ranged_search(catalog, {"query": topic, "n_items": N_ITEMS}, today, released)


def find_released(catalog, topic, today):
    items = [i for i in topic_search(catalog, topic, today, True) if not i.get("live_event_start_dates")]
    author = named_author(topic, items)
    if author:
        return author_pointer(topic, author)
    released, _ = ordered(items, today)
    return {"released": released}


def find_scheduled(catalog, topic, today):
    """Announced recorded content; live events are find_live_events' business."""
    found = [i for i in topic_search(catalog, topic, today, False) if not i.get("live_event_start_dates")]
    author = named_author(topic, found)
    if author:
        return author_pointer(topic, author)
    _, scheduled = ordered(found, today)
    return {"scheduled": scheduled}


AUTHOR_GROUPS = (("books", BOOK_TYPES, N_BOOKS), ("other formats", OTHER_TYPES, N_ITEMS))


def author_group(catalog, name, group, today):
    """One format group of an author's raw items, released and scheduled.

    Returns (released, scheduled, notes): the notes name a search that failed or that hit its limit.
    """
    label, content_types, limit = group
    common = {"query": "*", "author_filter": [name], "content_types": content_types, "n_items": limit,
              "order_by": "date_published"}
    found, notes = {}, []
    for released, order in ((True, "desc"), (False, "asc")):
        status = "released" if released else "scheduled"
        try:
            items = ranged_search(catalog, {**common, "sort_order": order}, today, released)
        except CatalogError as err:
            found[released] = None
            notes.append(f"the {status} {label} could not be searched ({err})")
            continue
        found[released] = items
        if len(items) >= limit:
            notes.append(f"the {status} {label} reached the limit of {limit}, so older or later ones may be missing")
    return found[True], found[False], notes


def live_search(catalog, arguments):
    """Upcoming live events. The catalog never returns past ones and its publication_date is not the
    session date, so a date range would drop events; the order is the soonest session first."""
    return catalog.search({**arguments, "content_types": LIVE_TYPES, "n_items": N_ITEMS,
                           "order_by": "upcoming_events", "sort_order": "asc"})


def author_live_events(catalog, name, wanted, today):
    """(upcoming live events of the author, notes naming a failed search)."""
    try:
        items = live_search(catalog, {"query": "*", "author_filter": [name]})
    except CatalogError as err:
        return None, [f"the live events could not be searched ({err})"]
    scheduled = [i for i in items if has_author(i, wanted) and status_of(i, today) == "Scheduled"]
    if len(items) >= N_ITEMS:
        return scheduled, [f"the live events reached the limit of {N_ITEMS}, so later ones may be missing"]
    return scheduled, []


def find_by_author(catalog, name, today):
    """The author's books and the newest items of the other formats, each group searched on its own.

    A failed or capped search is named in the message; the tool fails only when every search failed.
    """
    wanted = name_tokens(name)
    if not wanted:
        return {"message": "Give the author's full name (first and last name)."}
    books = author_group(catalog, name, AUTHOR_GROUPS[0], today)
    other = author_group(catalog, name, AUTHOR_GROUPS[1], today)
    live, live_notes = author_live_events(catalog, name, wanted, today)
    if live is None and all(found is None for group in (books, other) for found in group[:2]):
        raise CatalogError("every author search failed")
    mine_books = [i for i in merge_unique(books[0] or [], books[1] or []) if has_author(i, wanted)]
    in_books = {item_key(i) for i in mine_books}
    mine_other = [i for i in merge_unique(other[0] or [], other[1] or [])
                  if has_author(i, wanted) and item_key(i) not in in_books]
    notes = books[2] + other[2] + live_notes
    names = matching_names([*mine_books, *mine_other, *(live or [])], wanted)
    if len(names) > 1:
        payload = split_by_author(names, mine_books, mine_other, live or [], today)
    else:
        payload = author_lists(mine_books, mine_other, live or [], today)
    if notes:
        payload["message"] = (payload.get("message", "") + " Part of this list may be missing: "
                              + "; ".join(notes) + ".").strip()
    return payload


def author_lists(mine_books, mine_other, live, today):
    released_books, scheduled_books = ordered(mine_books, today)
    released_other, scheduled_other = ordered(mine_other, today)
    return {"released_books": released_books, "scheduled_books": scheduled_books,
            "released_other_formats": released_other, "scheduled_other_formats": scheduled_other,
            "upcoming_live_events": ordered(live, today)[1]}


def matching_names(items, wanted):
    """The author strings, exactly as the catalog lists them, that match the wanted name."""
    return sorted({a for i in items for a in i.get("authors") or [] if wanted <= name_tokens(a)})


def common(items, key, limit=5):
    """The most common string values of a field, or of each entry of a list field; other values are skipped."""
    counts = {}
    for item in items:
        value = item.get(key)
        for text in value if isinstance(value, list) else [value]:
            if isinstance(text, str) and text:
                counts[text] = counts.get(text, 0) + 1
    return [t for t, _ in sorted(counts.items(), key=lambda p: (-p[1], p[0]))[:limit]]


def topics_of(items, limit=5):
    """What the items are about: their most common tags, then the first titles (tags are often empty)."""
    titles = [i["title"] for i in items if i.get("title")][:3]
    return [*common(items, "tags", limit), *titles]


def split_by_author(names, mine_books, mine_other, live, today):
    """One group per author string; an item is in the group of each matching string it lists."""
    groups = []
    for name in names:
        def own(items, name=name):
            return [i for i in items if name in (i.get("authors") or [])]
        lists = author_lists(own(mine_books), own(mine_other), own(live), today)
        items = [*own(mine_books), *own(mine_other), *own(live)]
        counts = {key: len(value) for key, value in lists.items()}
        groups.append({"author": name, "item_counts": counts, "topics": topics_of(items),
                       "formats": common(items, "marketing_type"), "publishers": common(items, "publisher_names"),
                       **lists})
    listed = ", ".join(f'"{n}"' for n in names)
    return {"message": f"The name matches {len(names)} different author entries in the catalog: {listed}. They may "
                       "be different people or one person listed two ways. Each group below is one entry, not "
                       "merged. Ask which one is meant or pick by topic.",
            "authors": groups}


def find_title(catalog, title, today):
    """A named item whatever its date, best match first."""
    items = catalog.search({"query": title, "n_items": TITLE_ITEMS})
    ranked = sorted(items, key=lambda i: i.get("relevance_score") or 0, reverse=True)
    return {"items": [shape(i, today) for i in ranked]}


def find_live_events(catalog, topic, today):
    items = live_search(catalog, {"query": topic})
    author = named_author(topic, items)
    if author:
        return author_pointer(topic, author)
    _, scheduled = ordered(items, today)
    return {"scheduled": scheduled}


HANDLERS = {
    "find_released": find_released,
    "find_scheduled": find_scheduled,
    "find_by_author": find_by_author,
    "find_title": find_title,
    "find_live_events": find_live_events,
}


def with_note(description, note):
    """The tool description with the access sentence appended, when there is one."""
    return f"{description} {note}" if note and note not in description else description


def expert_listing(note=""):
    return [{
        "name": t["name"],
        "description": with_note(t["description"], note),
        "inputSchema": {"type": "object", "properties": t["properties"], "required": t["required"]},
    } for t in EXPERT_TOOLS]


def expert_arguments(tool, arguments):
    """The upstream arguments for an Expert tool, or a reason the call is malformed."""
    if not isinstance(arguments, dict):
        return None, f"{tool['name']} needs its arguments as an object"
    sent = {}
    for key, value in arguments.items():
        spec = tool["properties"].get(key)
        if spec is None or value is None:
            continue
        if key in tool["text"]:
            if not isinstance(value, str) or not value.strip() or len(value) > MAX_QUESTION_CHARS:
                return None, f"{key} must be text of at most {MAX_QUESTION_CHARS} characters"
            sent[key] = value.strip()
        elif isinstance(value, bool) or not isinstance(value, int):
            return None, f"{key} must be a whole number"
        else:
            sent[key] = value
    missing = [k for k in tool["required"] if k not in sent]
    if missing:
        return None, f"{tool['name']} needs {', '.join(missing)}"
    return sent, ""


def call_expert(name, arguments, catalog):
    """A tools/call result for an Expert tool: O'Reilly's passages as returned, or an error to read."""
    tool = EXPERT_BY_NAME[name]
    sent, problem = expert_arguments(tool, arguments)
    if sent is None:
        return text_result(problem, True)
    try:
        return text_result(catalog.call(tool["upstream"], sent))
    except EntitlementError as err:
        return text_result(str(err), True)
    except CatalogError as err:
        return text_result(f"The O'Reilly Expert tools could not answer: {err}", True)


def tool_listing(note=""):
    return [{
        "name": t["name"],
        "description": with_note(t["description"], note),
        "inputSchema": {
            "type": "object",
            "properties": {t["argument"]: {"type": "string", "description": t["argument_description"]}},
            "required": [t["argument"]],
        },
    } for t in TOOLS]


def text_result(text, is_error=False):
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


def argument_of(name, arguments):
    """The tool's single argument, or None when it is missing, not text, or too long."""
    wanted = next(t["argument"] for t in TOOLS if t["name"] == name)
    value = arguments.get(wanted) if isinstance(arguments, dict) else None
    if not isinstance(value, str) or not value.strip() or len(value) > MAX_ARGUMENT_CHARS:
        return None
    return value.strip()


class RecentCalls:
    """Remembers successful searches and their results for a short while, so a repeat is answered
    from memory, whichever caller of the thread made the first search. It holds at most
    max_entries searches (the oldest go first) however many distinct searches arrive."""

    def __init__(self, clock=time.monotonic, window=REPEAT_SECONDS, max_entries=MAX_REMEMBERED_CALLS):
        self._clock, self._window, self._max, self._seen = clock, window, max_entries, {}

    def _prune(self):
        now = self._clock()
        self._seen = {k: v for k, v in self._seen.items() if now - v[0] < self._window}

    def earlier(self, key):
        """The result of the same search run within the window, or None."""
        self._prune()
        return self._seen[key][1] if key in self._seen else None

    def remember(self, key, result):
        self._prune()
        self._seen.pop(key, None)
        self._seen[key] = (self._clock(), result)
        while len(self._seen) > self._max:
            del self._seen[next(iter(self._seen))]


REPEAT_NOTE = ("This repeats an identical search run moments ago in this thread, so these are the same results "
               "as before; search with different keywords for anything new.")


def call_key(name, value, meta):
    """The identity of a search: the tool, the argument, and the thread when the call names one."""
    meta = meta if isinstance(meta, dict) else {}
    thread = meta.get("threadId") or meta.get("conversationId") or ""
    return (str(thread), name, " ".join(value.lower().split()))


def with_nothing_found(payload, value, today):
    """A plain 'nothing found' message when a search returned no items."""
    lists = [v for v in payload.values() if isinstance(v, list)]
    if "message" in payload or any(lists):
        return payload
    return {**payload, "message": f"Nothing found for '{value}' in the O'Reilly catalog as of {today.isoformat()}."}


def call_tool(name, arguments, catalog, today, source="the default time zone UTC", recent=None, meta=None):
    """A tools/call result: the search results, or an error the model can read."""
    value = argument_of(name, arguments)
    if value is None:
        return text_result(f"{name} needs its one text argument (at most {MAX_ARGUMENT_CHARS} characters)", True)
    key = call_key(name, value, meta)
    earlier = recent.earlier(key) if recent else None
    if earlier is not None:
        return text_result(json.dumps({"repeat": REPEAT_NOTE, **earlier}, ensure_ascii=False))
    try:
        found = with_nothing_found(HANDLERS[name](catalog, value, today), value, today)
        payload = {"today": today.isoformat(), "dateSource": source, **found}
        if recent:
            recent.remember(key, payload)
        return text_result(json.dumps(payload, ensure_ascii=False))
    except EntitlementError as err:
        return text_result(str(err), True)
    except CatalogError as err:
        return text_result(f"The O'Reilly catalog could not be searched: {err}", True)
    except (KeyError, TypeError, ValueError, AttributeError):
        return text_result("The O'Reilly catalog could not be searched: it answered in a shape this server "
                           "does not know", True)


def error_reply(ident, code, text):
    return {"jsonrpc": "2.0", "id": ident, "error": {"code": code, "message": text}}


def scoped(catalog, meta):
    """The catalog for one call: with relay on, the asker's context rides on its gateway calls."""
    narrow = getattr(catalog, "scoped", None)
    return narrow(meta) if narrow else catalog


def handle(message, catalog, default_zone="UTC", now_fn=utc_now, recent=None, expert=False, note=""):
    """The reply to one JSON-RPC message, or None for a notification."""
    if not isinstance(message, dict):
        return error_reply(None, -32600, "a request is a JSON object")
    method, ident = message.get("method", ""), message.get("id")
    params = message.get("params") if isinstance(message.get("params"), dict) else {}
    if ident is None:
        return None
    if method == "initialize":
        result = {"protocolVersion": params.get("protocolVersion") or PROTOCOL_VERSION,
                  "capabilities": {"tools": {"listChanged": False}},
                  "serverInfo": {"name": SERVER_NAME, "version": "1"}}
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": tool_listing(note) + (expert_listing(note) if expert else [])}
    elif method == "tools/call" and params.get("name") in HANDLERS:
        today, source = resolve_today(params.get("_meta"), default_zone, now_fn())
        result = call_tool(params["name"], params.get("arguments"), scoped(catalog, params.get("_meta")),
                           today, source, recent, params.get("_meta"))
    elif method == "tools/call" and expert and params.get("name") in EXPERT_BY_NAME:
        result = call_expert(params["name"], params.get("arguments"), scoped(catalog, params.get("_meta")))
    else:
        return error_reply(ident, -32602 if method == "tools/call" else -32601, "cannot handle that request")
    return {"jsonrpc": "2.0", "id": ident, "result": result}


def serve(catalog, stdin=sys.stdin, stdout=sys.stdout, default_zone="UTC", expert=False, note=""):
    recent = RecentCalls()
    for line in stdin:
        if not line.strip():
            continue
        try:
            reply = handle(json.loads(line), catalog, default_zone, recent=recent, expert=expert, note=note)
        except ValueError:
            reply = error_reply(None, -32700, "parse error")
        except Exception:  # noqa: BLE001 - one bad message never ends the process the bridge talks to
            reply = error_reply(None, -32603, "internal error")
        if reply is not None:
            stdout.write(json.dumps(reply) + "\n")
            stdout.flush()


def main():
    gateway = os.environ.get("OREILLY_GATEWAY_URL", "")
    if not gateway:
        sys.stderr.write("OREILLY_GATEWAY_URL must be set\n")
        return 2
    per_person = os.environ.get("OREILLY_PER_PERSON", "").lower() == "true"
    serve(GatewayCatalog(gateway, relay=per_person), default_zone=os.environ.get("OREILLY_DEFAULT_TIMEZONE", "UTC"),
          expert=os.environ.get("OREILLY_EXPERT", "").lower() == "true",
          note=os.environ.get("OREILLY_ACCESS_NOTE", "") if per_person else "")
    return 0


if __name__ == "__main__":
    sys.exit(main())
