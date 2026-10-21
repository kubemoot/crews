"""Tests for server.py. Run from the repository root:

    python3 -I -m unittest discover -s oguide-crew/search-server -p 'test_*.py'
"""
import contextlib
import datetime
import http.client
import io
import json
import os
import socket
import threading
import unittest
import urllib.error
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import ClassVar

import server

TODAY = datetime.date(2026, 10, 20)
NOW = datetime.datetime(2026, 10, 20, 12, 0, tzinfo=datetime.timezone.utc)
KEY = "sekret-key-value-123"


def book(title, date, **extra):
    return {"title": title, "authors": ["A. Author"], "marketing_type": "book", "publication_date": date,
            "url": f"https://learning.oreilly.com/library/view/-/{title.replace(' ', '')}/", "page_count": 100,
            **extra}


def event(title, sessions, published="2026-08-01"):
    return {"title": title, "authors": ["E. Teacher"], "marketing_type": "live course",
            "publication_date": published, "live_event_start_dates": sessions,
            "url": f"https://learning.oreilly.com/live-events/-/{title.replace(' ', '')}/"}


class FakeCatalog:
    """Answers each search with the next prepared list and records the arguments."""

    def __init__(self, *answers, error=None):
        self.answers, self.calls, self.error = list(answers), [], error

    def search(self, arguments):
        self.calls.append(arguments)
        if self.error:
            raise self.error
        return self.answers.pop(0) if self.answers else []


class StatusTest(unittest.TestCase):
    def status(self, item):
        return server.status_of(item, TODAY)

    def test_published_today_is_released(self):
        self.assertEqual("Released", self.status(book("T", "2026-10-20")))

    def test_published_yesterday_is_released(self):
        self.assertEqual("Released", self.status(book("T", "2026-10-19")))

    def test_published_tomorrow_is_scheduled(self):
        self.assertEqual("Scheduled", self.status(book("T", "2026-10-21")))

    def test_a_timestamp_uses_its_date_part(self):
        self.assertEqual("Scheduled", self.status(book("T", "2026-10-21T00:00:00Z")))

    def test_an_item_without_a_date_is_released(self):
        self.assertEqual("Released", self.status(book("T", "")))

    def test_a_live_event_with_a_session_today_is_scheduled(self):
        self.assertEqual("Scheduled", self.status(event("E", ["2026-10-19", "2026-10-20"])))

    def test_a_live_event_whose_sessions_are_past_is_released(self):
        self.assertEqual("Released", self.status(event("E", ["2026-10-19"])))

    def test_the_label_ignores_the_publication_date_of_an_event(self):
        self.assertEqual("Scheduled", self.status(event("E", ["2026-12-01"], published="2026-01-01")))


class OrderingTest(unittest.TestCase):
    def test_released_newest_first_and_scheduled_soonest_first(self):
        items = [book("Old", "2020-01-01"), book("Next", "2027-02-25"), book("New", "2026-09-01"),
                 book("Soon", "2026-10-27"), event("Later", ["2026-12-11"]), event("Sooner", ["2026-10-22"])]
        released, scheduled = server.ordered(items, TODAY)
        self.assertEqual(["New", "Old"], [e["title"] for e in released])
        self.assertEqual(["Sooner", "Soon", "Later", "Next"], [e["title"] for e in scheduled])

    def test_an_event_sorts_by_its_next_session_not_a_past_one(self):
        items = [event("Two", ["2026-10-01", "2026-12-01"]), event("One", ["2026-11-01"])]
        _, scheduled = server.ordered(items, TODAY)
        self.assertEqual(["One", "Two"], [e["title"] for e in scheduled])

    def test_an_item_keeps_the_catalog_values_and_gets_a_status(self):
        shaped = server.shape(book("T", "2026-01-01", unknown_field="x"), TODAY)
        self.assertEqual({"title", "authors", "format", "publication_date", "page_count", "status", "url"},
                         set(shaped))
        self.assertEqual("book", shaped["format"])


class SearchArgumentsTest(unittest.TestCase):
    def test_find_released_filters_to_dates_up_to_today(self):
        catalog = FakeCatalog([book("A", "2026-01-01")])
        out = server.find_released(catalog, "vector databases", TODAY)
        call = catalog.calls[0]
        self.assertEqual("vector databases", call["query"])
        self.assertEqual(25, call["n_items"])
        self.assertNotIn("content_types", call)
        self.assertEqual("2026-10-20", call["date_range"]["end_date"])
        self.assertNotIn("start_date", call["date_range"])
        self.assertEqual(["A"], [e["title"] for e in out["released"]])

    def test_find_scheduled_filters_to_dates_from_today(self):
        catalog = FakeCatalog([book("B", "2027-01-01")])
        out = server.find_scheduled(catalog, "agents", TODAY)
        self.assertEqual("2026-10-20", catalog.calls[0]["date_range"]["start_date"])
        self.assertNotIn("end_date", catalog.calls[0]["date_range"])
        self.assertEqual("Scheduled", out["scheduled"][0]["status"])

    def test_scheduled_recorded_content_leaves_live_events_out(self):
        catalog = FakeCatalog([book("B", "2027-01-01"), event("Live", ["2026-12-01"])])
        out = server.find_scheduled(catalog, "agents", TODAY)
        self.assertEqual(["B"], [e["title"] for e in out["scheduled"]])

    def test_the_author_search_makes_two_calls(self):
        catalog = FakeCatalog([book("Past", "2025-01-01")], [book("Future", "2027-02-25")])
        out = server.find_by_author(catalog, "Neal Ford", TODAY)
        past, future = catalog.calls
        self.assertEqual(["Neal Ford"], past["author_filter"])
        self.assertEqual("*", past["query"])
        self.assertEqual("2026-10-20", past["date_range"]["end_date"])
        self.assertEqual("desc", past["sort_order"])
        self.assertEqual("2026-10-20", future["date_range"]["start_date"])
        self.assertEqual("asc", future["sort_order"])
        self.assertEqual(["Past"], [e["title"] for e in out["released"]])
        self.assertEqual(["Future"], [e["title"] for e in out["scheduled"]])

    def test_an_item_in_both_author_calls_appears_once(self):
        shared = event("Both", ["2026-12-01"])
        out = server.find_by_author(FakeCatalog([shared], [shared]), "N", TODAY)
        self.assertEqual(1, len(out["released"]) + len(out["scheduled"]))

    def test_live_events_use_the_live_event_type_and_no_date_filter(self):
        catalog = FakeCatalog([event("E", ["2026-11-01"])])
        out = server.find_live_events(catalog, "agentic AI", TODAY)
        call = catalog.calls[0]
        self.assertEqual(["live-events"], call["content_types"])
        self.assertEqual("upcoming_events", call["order_by"])
        self.assertNotIn("date_range", call)
        self.assertEqual("Scheduled", out["scheduled"][0]["status"])

    def test_the_model_cannot_supply_dates_or_counts(self):
        catalog = FakeCatalog([])
        server.call_tool("find_released", {"topic": "x", "n_items": 3, "date_range": {"end_date": "2000-01-01"}},
                         catalog, TODAY)
        self.assertEqual(25, catalog.calls[0]["n_items"])
        self.assertEqual("2026-10-20", catalog.calls[0]["date_range"]["end_date"])


class ToolCallTest(unittest.TestCase):
    def test_a_missing_argument_is_an_error_the_model_can_read(self):
        result = server.call_tool("find_released", {}, FakeCatalog(), TODAY)
        self.assertTrue(result["isError"])
        self.assertIn("needs its one text argument", result["content"][0]["text"])

    def test_an_argument_that_is_not_text_is_refused(self):
        self.assertTrue(server.call_tool("find_by_author", {"name": ["a"]}, FakeCatalog(), TODAY)["isError"])

    def test_a_very_long_argument_is_refused(self):
        long = "x" * (server.MAX_ARGUMENT_CHARS + 1)
        self.assertTrue(server.call_tool("find_released", {"topic": long}, FakeCatalog(), TODAY)["isError"])

    def test_an_unreachable_catalog_is_a_clear_failure(self):
        catalog = FakeCatalog(error=server.CatalogError("the catalog is unreachable (URLError)"))
        result = server.call_tool("find_released", {"topic": "x"}, catalog, TODAY)
        self.assertTrue(result["isError"])
        self.assertEqual("The O'Reilly catalog could not be searched: the catalog is unreachable (URLError)",
                         result["content"][0]["text"])

    def test_an_empty_result_is_not_an_error(self):
        result = server.call_tool("find_released", {"topic": "zzz"}, FakeCatalog([]), TODAY)
        self.assertFalse(result["isError"])
        self.assertEqual([], json.loads(result["content"][0]["text"])["released"])


class ProtocolTest(unittest.TestCase):
    def reply(self, message):
        return server.handle(message, FakeCatalog(), "UTC", lambda: NOW)

    def test_initialize_answers_with_the_clients_protocol_version(self):
        out = self.reply({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                          "params": {"protocolVersion": "2025-06-18"}})
        self.assertEqual("2025-06-18", out["result"]["protocolVersion"])
        self.assertIn("tools", out["result"]["capabilities"])

    def test_a_notification_gets_no_reply(self):
        self.assertIsNone(self.reply({"jsonrpc": "2.0", "method": "notifications/initialized"}))

    def test_tools_list_names_the_four_tools_with_one_argument_each(self):
        tools = self.reply({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})["result"]["tools"]
        self.assertEqual(["find_released", "find_scheduled", "find_by_author", "find_live_events"],
                         [t["name"] for t in tools])
        for tool in tools:
            self.assertEqual(1, len(tool["inputSchema"]["properties"]))

    def test_an_unknown_tool_is_a_protocol_error(self):
        out = self.reply({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "search"}})
        self.assertEqual(-32602, out["error"]["code"])

    def test_an_unknown_method_is_a_protocol_error(self):
        self.assertEqual(-32601, self.reply({"jsonrpc": "2.0", "id": 4, "method": "nope"})["error"]["code"])

    def test_serve_answers_line_by_line_and_survives_garbage(self):
        stdin = io.StringIO('{"jsonrpc":"2.0","id":1,"method":"ping"}\nnot json\n\n')
        stdout = io.StringIO()
        server.serve(FakeCatalog(), stdin, stdout)
        lines = [json.loads(line) for line in stdout.getvalue().splitlines()]
        self.assertEqual({}, lines[0]["result"])
        self.assertEqual(-32700, lines[1]["error"]["code"])


def call_with(meta, default_zone="UTC", now=NOW):
    """The text result of a find_released call carrying this _meta."""
    params = {"name": "find_released", "arguments": {"topic": "x"}}
    if meta is not _ABSENT:
        params["_meta"] = meta
    reply = server.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": params},
                          FakeCatalog([]), default_zone, lambda: now)
    return json.loads(reply["result"]["content"][0]["text"])


_ABSENT = object()


class RequesterDateTest(unittest.TestCase):
    def test_the_request_date_wins_over_everything(self):
        out = call_with({"requestDate": "2026-03-04", "timeZone": "Asia/Tokyo"}, "UTC")
        self.assertEqual("2026-03-04", out["today"])
        self.assertEqual("the request date", out["dateSource"])

    def test_a_time_zone_gives_the_date_in_that_zone(self):
        evening = datetime.datetime(2026, 10, 20, 20, 0, tzinfo=datetime.timezone.utc)
        out = call_with({"timeZone": "Asia/Tokyo"}, "UTC", evening)
        self.assertEqual("2026-10-21", out["today"])
        self.assertEqual("the request time zone Asia/Tokyo", out["dateSource"])

    def test_a_request_at_2330_in_los_angeles_is_still_that_date_after_utc_rolled_over(self):
        now = datetime.datetime(2026, 10, 21, 6, 30, tzinfo=datetime.timezone.utc)  # 23:30 PDT on the 20th
        self.assertEqual("2026-10-21", call_with(_ABSENT, "UTC", now)["today"])
        out = call_with({"timeZone": "America/Los_Angeles"}, "UTC", now)
        self.assertEqual("2026-10-20", out["today"])

    def test_without_meta_the_default_zone_is_used_and_named(self):
        now = datetime.datetime(2026, 10, 21, 6, 30, tzinfo=datetime.timezone.utc)
        out = call_with(_ABSENT, "America/New_York", now)
        self.assertEqual("2026-10-21", out["today"])
        self.assertEqual("the default time zone America/New_York", out["dateSource"])

    def test_the_default_zone_is_utc_when_nothing_is_set(self):
        out = call_with(_ABSENT)
        self.assertEqual("2026-10-20", out["today"])
        self.assertEqual("the default time zone UTC", out["dateSource"])

    def test_malformed_meta_values_fall_back(self):
        for meta in ({"requestDate": "tomorrow"}, {"requestDate": 20261020}, {"timeZone": "Mars/Base"},
                     {"timeZone": 5}, {"requestDate": "2026-13-45"}, "not an object", None, []):
            out = call_with(meta)
            self.assertEqual("2026-10-20", out["today"], meta)
            self.assertEqual("the default time zone UTC", out["dateSource"], meta)

    def test_a_bad_default_zone_falls_back_to_utc(self):
        self.assertEqual("the default time zone UTC", call_with(_ABSENT, "Not/AZone")["dateSource"])

    def test_the_date_is_never_taken_from_the_arguments(self):
        arguments = {"topic": "x", "today": "1999-01-01", "requestDate": "1999-01-01"}
        params = {"name": "find_released", "arguments": arguments}
        reply = server.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": params},
                              FakeCatalog([]), "UTC", lambda: NOW)
        self.assertEqual("2026-10-20", json.loads(reply["result"]["content"][0]["text"])["today"])

    def test_the_status_labels_follow_the_requesters_date(self):
        catalog = FakeCatalog([book("B", "2026-10-21")])
        reply = server.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
            "name": "find_by_author", "arguments": {"name": "N"}, "_meta": {"requestDate": "2026-10-21"}}},
            catalog, "UTC", lambda: NOW)
        payload = json.loads(reply["result"]["content"][0]["text"])
        self.assertEqual("Released", payload["released"][0]["status"])


class Gateway(BaseHTTPRequestHandler):
    """A stand-in for the crew's MCP gateway tool endpoint."""
    status = 200
    reply = None
    seen: ClassVar[dict] = {}

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        type(self).seen = {"path": self.path, "headers": dict(self.headers), "body": body}
        results = {"search_results": {"u1": book("Served", "2026-01-01")}}
        reply = type(self).reply
        if reply is None:
            reply = {"isError": False, "content": json.dumps(results)}
        self.send_response(type(self).status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(reply).encode())

    def log_message(self, *args):
        pass


class GatewayHttpTest(unittest.TestCase):
    def setUp(self):
        Gateway.status, Gateway.reply, Gateway.seen = 200, None, {}
        self.httpd = HTTPServer(("127.0.0.1", 0), Gateway)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.catalog = server.GatewayCatalog(f"http://127.0.0.1:{self.httpd.server_port}/")

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def test_the_search_goes_to_the_gateway_tool_endpoint_with_only_the_arguments(self):
        items = self.catalog.search({"query": "x", "n_items": 25})
        self.assertEqual("/tools/search_oreilly_content/call", Gateway.seen["path"])
        self.assertEqual({"arguments": {"query": "x", "n_items": 25}}, Gateway.seen["body"])
        self.assertEqual("Served", items[0]["title"])

    def test_no_key_or_auth_header_is_sent(self):
        self.catalog.search({"query": "x"})
        self.assertNotIn("Authorization", Gateway.seen["headers"])
        self.assertNotIn("X-Api-Key", Gateway.seen["headers"])

    def test_a_tool_error_from_the_gateway_is_a_clear_failure(self):
        Gateway.reply = {"isError": True, "content": "Tool not found: search_oreilly_content"}
        with self.assertRaises(server.CatalogError) as raised:
            self.catalog.search({"query": "x"})
        self.assertEqual("the gateway said: Tool not found: search_oreilly_content", str(raised.exception))

    def test_an_upstream_message_without_results_is_a_clear_failure(self):
        Gateway.reply = {"isError": False, "content": "Input validation error: '2' is not of type 'integer'"}
        with self.assertRaises(server.CatalogError) as raised:
            self.catalog.search({"query": "x"})
        self.assertIn("the catalog did not return results: Input validation error", str(raised.exception))

    def test_a_long_upstream_message_is_cut(self):
        Gateway.reply = {"isError": True, "content": "x" * 1000}
        with self.assertRaises(server.CatalogError) as raised:
            self.catalog.search({"query": "x"})
        self.assertLess(len(str(raised.exception)), 200)

    def test_an_http_error_from_the_gateway_is_a_clear_failure(self):
        Gateway.status = 503
        with self.assertRaises(server.CatalogError) as raised:
            self.catalog.search({"query": "x"})
        self.assertIn("HTTP 503", str(raised.exception))

    def test_an_unreachable_gateway_is_a_clear_failure(self):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            closed_port = probe.getsockname()[1]
        with self.assertRaises(server.CatalogError) as raised:
            server.GatewayCatalog(f"http://127.0.0.1:{closed_port}").search({"query": "x"})
        self.assertIn("unreachable", str(raised.exception))

    def test_a_reply_that_is_not_the_gateway_shape_fails(self):
        for reply in ([], "text", {"nope": 1}, {"content": None}):
            Gateway.reply = reply
            with self.assertRaises(server.CatalogError):
                self.catalog.search({"query": "x"})

    def test_a_tool_failure_reaches_the_model_as_an_mcp_error_result(self):
        Gateway.reply = {"isError": True, "content": "Tool not found: search_oreilly_content"}
        result = server.call_tool("find_released", {"topic": "x"}, self.catalog, TODAY)
        self.assertTrue(result["isError"])
        self.assertTrue(result["content"][0]["text"].startswith("The O'Reilly catalog could not be searched:"))

    def test_the_reply_is_bounded(self):
        class Big:
            def read(self, limit):
                return b"x" * limit

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False
        with self.assertRaises(server.CatalogError):
            server.GatewayCatalog("http://x", opener=lambda request, timeout: Big()).search({})

    def test_a_connection_cut_mid_reply_is_a_clear_failure(self):
        class Cut:
            def read(self, limit):
                raise http.client.IncompleteRead(b"part")

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False
        with self.assertRaises(server.CatalogError) as raised:
            server.GatewayCatalog("http://x", opener=lambda request, timeout: Cut()).search({})
        self.assertIn("unreachable", str(raised.exception))

    def test_the_timeout_is_passed_and_a_timeout_is_a_clear_failure(self):
        seen = []

        def opener(request, timeout):
            seen.append(timeout)
            raise TimeoutError("slow")
        with self.assertRaises(server.CatalogError) as raised:
            server.GatewayCatalog("http://x", opener=opener).search({})
        self.assertEqual([server.TIMEOUT_SECONDS], seen)
        self.assertIn("unreachable", str(raised.exception))

    def test_an_http_error_object_from_the_opener_is_translated(self):
        def opener(request, timeout):
            raise urllib.error.HTTPError(request.full_url, 502, "bad", {}, None)
        with self.assertRaises(server.CatalogError):
            server.GatewayCatalog("http://x", opener=opener).search({})


class RobustnessTest(unittest.TestCase):
    def test_a_message_that_is_not_an_object_gets_an_error_reply(self):
        for message in ([], 5, "x"):
            self.assertEqual(-32600, server.handle(message, FakeCatalog())["error"]["code"])

    def test_params_that_are_not_an_object_are_ignored(self):
        out = server.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [1]}, FakeCatalog())
        self.assertEqual(4, len(out["result"]["tools"]))

    def test_arguments_that_are_not_an_object_are_refused(self):
        self.assertTrue(server.call_tool("find_released", ["x"], FakeCatalog(), TODAY)["isError"])

    def test_a_catalog_item_that_is_not_an_object_is_skipped(self):
        results = {"search_results": {"a": "junk", "b": book("B", "2026-01-01")}}
        items = server.items_from(json.dumps({"isError": False, "content": json.dumps(results)}))
        self.assertEqual(["B"], [i["title"] for i in items])

    def test_an_item_with_odd_field_types_is_an_error_not_a_crash(self):
        result = server.call_tool("find_released", {"topic": "x"}, FakeCatalog([{"publication_date": 20260101}]), TODAY)
        self.assertTrue(result["isError"])

    def test_any_failure_in_one_message_leaves_the_server_running(self):
        class Boom:
            def search(self, arguments):
                raise RuntimeError("secret detail " + KEY)
        stdin = io.StringIO('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"find_released",'
                            '"arguments":{"topic":"x"}}}\n{"jsonrpc":"2.0","id":2,"method":"ping"}\n')
        stdout = io.StringIO()
        server.serve(Boom(), stdin, stdout)
        replies = [json.loads(line) for line in stdout.getvalue().splitlines()]
        self.assertEqual(-32603, replies[0]["error"]["code"])
        self.assertEqual({}, replies[1]["result"])
        self.assertNotIn(KEY, stdout.getvalue())

    def test_a_missing_time_zone_database_falls_back_to_utc(self):
        real = server.zoneinfo.ZoneInfo
        def missing(name):
            raise server.zoneinfo.ZoneInfoNotFoundError(name)
        server.zoneinfo.ZoneInfo = missing
        try:
            today, source = server.resolve_today(None, "UTC", NOW)
        finally:
            server.zoneinfo.ZoneInfo = real
        self.assertEqual((TODAY, "the default time zone UTC"), (today, source))

    def test_a_catalog_call_times_out_within_fifteen_seconds(self):
        self.assertLessEqual(server.TIMEOUT_SECONDS, 15)


class MainTest(unittest.TestCase):
    def test_main_refuses_to_start_without_a_gateway_url(self):
        saved = {k: os.environ.pop(k, None) for k in ("OREILLY_GATEWAY_URL",)}
        try:
            with contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(2, server.main())
            self.assertIn("OREILLY_GATEWAY_URL must be set", err.getvalue())
        finally:
            for k, v in saved.items():
                if v is not None:
                    os.environ[k] = v


if __name__ == "__main__":
    unittest.main()
