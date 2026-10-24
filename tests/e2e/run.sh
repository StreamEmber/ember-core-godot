#!/usr/bin/env bash
# End-to-end test against fake Launcher/Falcon/EventFabric (needs python3 + websockets).
#   GODOT=/path/to/godot tests/e2e/run.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-godot}"
PORT="${PORT:-18765}"
WORK="$(mktemp -d)"
trap 'kill $SERVER 2>/dev/null || true; rm -rf "$WORK"' EXIT

cp -r "$ROOT/." "$WORK/project"
cat > "$WORK/project/override.cfg" <<CFG
[streamember]

falcon_url="http://127.0.0.1:$PORT"
launcher_url="http://127.0.0.1:$PORT"
presence_seconds=5
CFG

python3 "$ROOT/tests/e2e/fake_services.py" "$PORT" "$WORK/server.json" & SERVER=$!
sleep 1
"$GODOT" --headless --path "$WORK/project" --import >/dev/null 2>&1 || true
SE_E2E_OUT="$WORK/game.json" timeout 60 "$GODOT" --headless --path "$WORK/project" res://tests/e2e/e2e.tscn

python3 - "$WORK/game.json" "$WORK/server.json" <<'PY'
import json, sys
game = json.load(open(sys.argv[1])); server = json.load(open(sys.argv[2]))
print(json.dumps(game, indent=1))
failures = []
def check(ok, label):
    print(("ok   " if ok else "FAIL ") + label)
    if not ok: failures.append(label)
ids = [a["id"] for a in game["actions"]]
check(ids == ["a1", "a3"], "actions delivered once, other game dropped: %s" % ids)
check(game["actions"][0].get("count") == 3 and game["actions"][0].get("quantity") == 2, "schema default count=3, quantity=2")
check(game["actions"][1].get("text") == "Ali sends Rose x2", "render: %s" % game["actions"][1].get("text"))
check(game["settings"][:1] == [50] and 77 in game["settings"], "settings: schema default then Falcon: %s" % game["settings"])
check(game["teams"] == ["gs"], "teams from Falcon config: %s" % game["teams"])
check(game["connections"][:3] == [True, False, True], "connect, drop, reconnect: %s" % game["connections"])
check(game["gcore_reset"] is True and game["can_write"] is True, "session reset with secret key")
conns = server["ws_connections"]
check(len(conns) >= 2 and "replay=true&cursor=c3" in conns[1], "reconnect resumes from cursor: %s" % conns[1:2])
check(any(m.get("type") == "replay.next" and m.get("cursor") == "c3" for m in server["ws_received"]), "replay.next sent")
paths = [h["path"] for h in server["http"]]
check("/api/customer" in paths and "/api/active-application" in paths, "launcher customer + active application")
check(all(h["keyed"] for h in server["http"] if h["path"] in ("/presence/report", "/sessions/reset", "/api/active-application")) and "/presence/report" in paths, "writes carry the secret key")
check(not any(h["keyed"] for h in server["http"] if h["path"].startswith("/public/") or h["path"] == "/api/customer"), "key never sent on reads")
sys.exit(1 if failures else 0)
PY

# Phase 2: no launcher; the player signs in inside the game (fake Falcon auth on PORT+1).
FALCON_PORT=$((PORT + 1))
python3 "$ROOT/tests/e2e/fake_falcon.py" "$FALCON_PORT" "$PORT" "$WORK/falcon.json" & FALCON=$!
trap 'kill $SERVER $FALCON 2>/dev/null || true; rm -rf "$WORK"' EXIT
cat > "$WORK/project/override.cfg" <<CFG
[streamember]

falcon_url="http://127.0.0.1:$FALCON_PORT"
probe_launcher=false
collect="server"
presence_seconds=5
CFG
sleep 1
SE_E2E_OUT="$WORK/signin.json" timeout 60 "$GODOT" --headless --path "$WORK/project" res://tests/e2e/e2e_signin.tscn

python3 - "$WORK/signin.json" "$WORK/falcon.json" "$WORK/server.json" <<'PY'
import json, sys
game = json.load(open(sys.argv[1])); falcon = json.load(open(sys.argv[2])); server = json.load(open(sys.argv[3]))
print(json.dumps(game, indent=1))
failures = []
def check(ok, label):
    print(("ok   " if ok else "FAIL ") + label)
    if not ok: failures.append(label)
reqs = falcon["requests"]
check(game["before"] == "", "no identity before sign-in (solo play)")
check(game["wrong"] == {"ok": False, "code": "invalid_credentials"}, "wrong password: %s" % game["wrong"])
check(game["right"] == {"ok": True, "code": ""}, "sign-in: %s" % game["right"])
logins = [r for r in reqs if r["path"] == "/api/auth/login"]
check(logins[0]["body"]["client"]["app"] == "godot-demo" and logins[1]["body"]["client"]["app"] == "", "unknown game app falls back to the launcher app")
check(all(r["body"]["email"] == "ali@example.com" for r in logins[2:]), "e-mail trimmed + lower-cased")
keys = [r for r in reqs if r["path"] == "/api/me/device-keys"]
check(len(keys) == 1 and keys[0]["auth"] == "Bearer ses_e2e" and keys[0]["body"]["applicationUuid"] == "b68b5dcc-090e-48a9-bb38-e8c16886aab7", "device key asked with the session")
logouts = [r for r in reqs if r["path"] == "/api/auth/logout"]
check(len(logouts) >= 1 and logouts[0]["auth"] == "Bearer ses_e2e", "no shared store: session closed right after the device key")
check(game["customer"] == "11111111-2222-4333-8444-555555555555" and game["source"] == "device" and game["email"] == "ali@example.com", "identity from the sign-in")
check(game["targets"] == [{"platform": "tiktok", "target": "yayinci"}] and game["write_scope"] == "device", "targets + device key")
check(game["actions"] == ["a3"] and True in game["connections"], "live actions arrive after sign-in: %s" % game["actions"])
ws = server["ws_connections"][-1]
check("collect=self" in ws and "key=dek_e2e" in ws, "EventFabric collects with the device key: %s" % ws)
check(any(h["path"] == "/presence/report" and h["keyed"] for h in server["http"]), "presence with the device key")
check(not any("ses_" in json.dumps(h) for h in server["http"]) and not any("ses_" in c for c in server["ws_connections"]), "session token never reaches EventFabric")
check(game["after_sign_out"] == "" and game["stored_after"] is False, "sign-out forgets the identity")
sys.exit(1 if failures else 0)
PY
