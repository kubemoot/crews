"""O'guide search server: fixed O'Reilly catalog searches as an MCP server over stdio.

The model names a topic or an author. This server builds every search argument itself (the
date filters, the item count, the ordering), labels each item Released or Scheduled from its
own date against today's date, and sorts the results. It speaks MCP on stdin and stdout; the
operator's bridge connects it to the gateway.

Configuration comes from the environment:
  OREILLY_GATEWAY_URL        the crew's MCP gateway, which holds the O'Reilly key and forwards the search
  OREILLY_DEFAULT_TIMEZONE   IANA time zone whose date is "today" when a request carries none (default UTC)

The server holds no key. It calls the raw search tool through the gateway's tool endpoint
(POST <gateway>/tools/search_oreilly_content/call), as agents do.

"Today" is the requester's date, never the model's. A tools/call may carry it in params._meta:
  "requestDate"  an ISO date (YYYY-MM-DD); used as given
  "timeZone"     an IANA time zone name; today is the date now in that zone
requestDate wins over timeZone, which wins over the default zone. A value that is missing or
malformed is ignored. Every result says which date and which source it used.
"""
import datetime
import http.client
import json
import os
import sys
import urllib.error
import urllib.request
import zoneinfo

SERVER_NAME = "oguide-search"
PROTOCOL_VERSION = "2025-03-26"
N_ITEMS = 25
TIMEOUT_SECONDS = 15
MAX_REPLY_BYTES = 5_000_000
MAX_UPSTREAM_MESSAGE_CHARS = 160
MAX_ARGUMENT_CHARS = 300
SEARCH_TOOL = "search_oreilly_content"

TOOLS = [
    {
        "name": "find_released",
        "description": "Search the O'Reilly catalog for released books, videos, courses and other recorded "
                       "content on a topic. Every item is labelled Released and the list is newest first.",
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
        "description": "Find the work of one author in the O'Reilly catalog: released items newest first, then "
                       "scheduled items soonest first. Every item is labelled Released or Scheduled.",
        "argument": "name",
        "argument_description": "The author's full name",
    },
    {
        "name": "find_live_events",
        "description": "Search the O'Reilly catalog for upcoming live events and live courses on a topic, with "
                       "their session dates, soonest first.",
        "argument": "topic",
        "argument_description": "Descriptive keywords for the topic, not a question",
    },
]


class CatalogError(Exception):
    """The O'Reilly catalog could not be searched. The message is written for the model to read."""


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc)


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


def resolve_today(meta, default_zone, now):
    """The requester's date and where it came from: requestDate, then timeZone, then the default zone."""
    meta = meta if isinstance(meta, dict) else {}
    given = date_named(meta.get("requestDate"))
    if given:
        return given, "the request date"
    zone = zone_named(meta.get("timeZone"))
    if zone:
        return now.astimezone(zone).date(), f"the request time zone {zone.key}"
    fallback = zone_named(default_zone)
    if fallback:
        return now.astimezone(fallback).date(), f"the default time zone {fallback.key}"
    return now.astimezone(datetime.timezone.utc).date(), "the default time zone UTC"


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


def shape(item, today):
    """One result item: the catalog's own values plus the status label."""
    out = {
        "title": item.get("title"),
        "authors": item.get("authors") or [],
        "format": item.get("marketing_type") or item.get("display_format"),
        "publication_date": item.get("publication_date") or "",
    }
    for field in ("live_event_start_dates", "page_count", "duration"):
        if item.get(field):
            out[field] = item[field]
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


def merge_unique(first, second):
    """Both lists, an item once by its url."""
    seen, out = set(), []
    for item in first + second:
        key = item.get("url") or item.get("title")
        if key not in seen:
            seen.add(key)
            out.append(item)
    return out


class GatewayCatalog:
    """The O'Reilly catalog search, called through the crew's MCP gateway (which holds the key)."""

    def __init__(self, gateway_url, opener=None):
        self._url = f"{gateway_url.rstrip('/')}/tools/{SEARCH_TOOL}/call"
        self._open = opener or urllib.request.urlopen

    def search(self, arguments):
        """Run one catalog search and return its result items as a list of dicts."""
        body = json.dumps({"arguments": arguments}).encode()
        request = urllib.request.Request(self._url, data=body, method="POST",
                                         headers={"Content-Type": "application/json"})
        try:
            with self._open(request, timeout=TIMEOUT_SECONDS) as response:
                raw = response.read(MAX_REPLY_BYTES + 1)
        except urllib.error.HTTPError as err:
            code = err.code
            err.close()
            raise CatalogError(f"the gateway answered HTTP {code}") from None
        except (urllib.error.URLError, http.client.HTTPException, OSError, TimeoutError) as err:
            raise CatalogError(f"the gateway is unreachable ({type(err).__name__})") from None
        if len(raw) > MAX_REPLY_BYTES:
            raise CatalogError("the gateway answered with more than this server reads")
        return items_from(raw.decode("utf-8", "replace"))


def short(text):
    """The first line of an upstream message, bounded, for an error the model can read."""
    return " ".join(str(text).split())[:MAX_UPSTREAM_MESSAGE_CHARS]


def items_from(text):
    """The result items in a gateway tool reply {"isError": bool, "content": "<tool text>"}."""
    try:
        reply = json.loads(text)
        content, failed = reply["content"], bool(reply.get("isError"))
    except (ValueError, KeyError, TypeError, AttributeError):
        raise CatalogError("the gateway answered in a shape this server does not know") from None
    if failed:
        raise CatalogError(f"the gateway said: {short(content)}")
    try:
        payload = json.loads(content)
        return [item for item in payload["search_results"].values() if isinstance(item, dict)]
    except (ValueError, KeyError, TypeError, AttributeError):
        raise CatalogError(f"the catalog did not return results: {short(content)}") from None


def topic_search(catalog, topic, today, released):
    return catalog.search({"query": topic, "n_items": N_ITEMS, "date_range": release_range(today, released)})


def find_released(catalog, topic, today):
    released, _ = ordered(topic_search(catalog, topic, today, True), today)
    return {"released": released}


def find_scheduled(catalog, topic, today):
    """Announced recorded content; live events are find_live_events' business."""
    items = [i for i in topic_search(catalog, topic, today, False) if not i.get("live_event_start_dates")]
    _, scheduled = ordered(items, today)
    return {"scheduled": scheduled}


def find_by_author(catalog, name, today):
    common = {"query": "*", "author_filter": [name], "n_items": N_ITEMS, "order_by": "date_published"}
    past = catalog.search({**common, "sort_order": "desc", "date_range": release_range(today, True)})
    future = catalog.search({**common, "sort_order": "asc", "date_range": release_range(today, False)})
    released, scheduled = ordered(merge_unique(past, future), today)
    return {"released": released, "scheduled": scheduled}


def find_live_events(catalog, topic, today):
    items = catalog.search({"query": topic, "content_types": ["live-events"], "n_items": N_ITEMS,
                            "order_by": "upcoming_events", "sort_order": "asc"})
    _, scheduled = ordered(items, today)
    return {"scheduled": scheduled}


HANDLERS = {
    "find_released": find_released,
    "find_scheduled": find_scheduled,
    "find_by_author": find_by_author,
    "find_live_events": find_live_events,
}


def tool_listing():
    return [{
        "name": t["name"],
        "description": t["description"],
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


def call_tool(name, arguments, catalog, today, source="the default time zone UTC"):
    """A tools/call result: the search results, or an error the model can read."""
    value = argument_of(name, arguments)
    if value is None:
        return text_result(f"{name} needs its one text argument (at most {MAX_ARGUMENT_CHARS} characters)", True)
    try:
        payload = {"today": today.isoformat(), "dateSource": source, **HANDLERS[name](catalog, value, today)}
        return text_result(json.dumps(payload, ensure_ascii=False))
    except CatalogError as err:
        return text_result(f"The O'Reilly catalog could not be searched: {err}", True)
    except (KeyError, TypeError, ValueError, AttributeError):
        return text_result("The O'Reilly catalog could not be searched: it answered in a shape this server "
                           "does not know", True)


def error_reply(ident, code, text):
    return {"jsonrpc": "2.0", "id": ident, "error": {"code": code, "message": text}}


def handle(message, catalog, default_zone="UTC", now_fn=utc_now):
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
        result = {"tools": tool_listing()}
    elif method == "tools/call" and params.get("name") in HANDLERS:
        today, source = resolve_today(params.get("_meta"), default_zone, now_fn())
        result = call_tool(params["name"], params.get("arguments"), catalog, today, source)
    else:
        return error_reply(ident, -32602 if method == "tools/call" else -32601, "cannot handle that request")
    return {"jsonrpc": "2.0", "id": ident, "result": result}


def serve(catalog, stdin=sys.stdin, stdout=sys.stdout, default_zone="UTC"):
    for line in stdin:
        if not line.strip():
            continue
        try:
            reply = handle(json.loads(line), catalog, default_zone)
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
    serve(GatewayCatalog(gateway), default_zone=os.environ.get("OREILLY_DEFAULT_TIMEZONE", "UTC"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
