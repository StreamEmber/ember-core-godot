"""Fake Launcher + Falcon + EventFabric on one port for the end-to-end test (pip install websockets).

python fake_services.py <port> <report.json>
"""
import asyncio
import base64
import json
import sys
import time
from http import HTTPStatus
from urllib.parse import parse_qs, urlsplit

from websockets.asyncio.server import serve

CUSTOMER = "11111111-2222-4333-8444-555555555555"
APP = "b68b5dcc-090e-48a9-bb38-e8c16886aab7"
OTHER_APP = "00000000-0000-4000-8000-000000000000"


def b64(data: dict) -> str:
    return base64.urlsafe_b64encode(json.dumps(data).encode()).decode().rstrip("=")


SECRET_KEY = "sek_" + "x" * 40
report = {"http": [], "ws_connections": [], "ws_received": []}
report_path = sys.argv[2]


def save():
    with open(report_path, "w") as f:
        json.dump(report, f, indent=1)


def action(id_, name, cursor, app=APP, **extra):
    body = {"schemaVersion": 2, "id": id_, "action": name, "customerUuid": CUSTOMER, "applicationUuid": app,
            "quantity": 2, "viewer": {"username": "ali", "nickname": "Ali"}, "gift": {"name": "Rose"},
            "trigger": {"platform": "tiktok", "target": "yayinci"}}
    body.update(extra)
    return json.dumps({"packetType": "action", "cursor": cursor, "action": body})


def process_request(connection, request):
    url = urlsplit(request.path)
    if url.path == "/events/ws":
        return None  # WebSocket upgrade
    query = parse_qs(url.query)
    keyed = query.get("key") == [SECRET_KEY]
    report["http"].append({"path": url.path, "query": {k: v for k, v in query.items() if k != "key"}, "keyed": keyed})
    save()
    if url.path == "/api/customer":
        body = {"customerUuid": CUSTOMER, "secretKey": SECRET_KEY,
                "region": {"code": "tr", "eventFabricUrl": f"http://127.0.0.1:{PORT}"}}
    elif url.path == "/api/active-application":
        if not keyed:
            return connection.respond(HTTPStatus.FORBIDDEN, json.dumps({"status": 403, "code": "invalid_key"}))
        body = {}
    elif url.path == f"/public/customers/{CUSTOMER}/applications/{APP}/config":
        body = {"revision": "r7", "settings": {"boxes": {"maxAlive": 77}},
                "teams": [{"id": "t1", "code": "gs", "name": "Galatasaray", "shortName": "GS", "keywords": ["1"]}]}
    elif url.path in ("/presence/report", "/sessions/reset"):
        if not keyed:
            return connection.respond(HTTPStatus.UNAUTHORIZED, json.dumps({"status": 401, "code": "invalid_key", "message": "Secret key missing or wrong."}))
        body = {"ok": True}
    else:
        return connection.respond(HTTPStatus.NOT_FOUND, "{}")
    return connection.respond(HTTPStatus.OK, json.dumps(body))


async def handler(ws):
    index = len(report["ws_connections"])
    report["ws_connections"].append(ws.request.path)
    save()

    async def receive():
        async for message in ws:
            report["ws_received"].append(json.loads(message))
            save()

    reader = asyncio.create_task(receive())
    if index == 0:
        await ws.send(action("a1", "box.drop", "c1", arguments={}))
        await ws.send(action("a1", "box.drop", "c2"))                 # duplicate id
        await ws.send(action("a2", "box.drop", "c3", app=OTHER_APP))  # other game
        await ws.send(json.dumps({"packetType": "system", "system": {"type": "replay.completed", "hasMore": True}}))
        await asyncio.sleep(1.0)
        await ws.close()                                              # client must reconnect with cursor c3
    else:
        await ws.send(action("a3", "screen.message", "c4", arguments={"text": "{user} sends {gift} x{quantity}"}))
        await asyncio.Future()
    reader.cancel()


async def main():
    async with serve(handler, "127.0.0.1", int(sys.argv[1]), process_request=process_request):
        save()
        await asyncio.Future()


asyncio.run(main())
