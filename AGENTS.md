# StreamEmber Godot core — agent guide

Godot 4.3+ addon (`addons/streamember/`, autoload `StreamEmber`) that connects a Godot game to StreamEmber live
actions, plus a demo game (`demo/`). Ecosystem rules: `../docs/AGENTS.md`. Behaviour must stay identical to
`StreamEmber.Live` in `gtav-runtime-scripthook` / `rdr2-runtime-scripthook` (`source/scripting_v3/StreamEmber.Live/`);
when one changes, port the change to the other.

## Layout

```
addons/streamember/
  plugin.cfg, plugin.gd          editor plugin: autoload + streamember/* project settings
  streamember.gd                 the core (autoload): identity, token, settings, presence, dispatch, hotkeys, log
  event_fabric_client.gd         WebSocket: replay cursor, backoff, ping, frame handling
  streamember_action.gd          StreamEmberAction (GameAction v2)
  streamember_values.gd          StreamEmberValues (dotted-path reader)
  streamember_manifest.gd        StreamEmberManifest (streamember-module.json + game-schema.json)
  streamember_json.gd            JSON helpers
streamember/                     the demo's manifest and schema (a game ships its own)
demo/                            example game: handlers, settings, bounded work, cleanup
tests/run_tests.gd               headless unit tests (no network)
tests/e2e/                       fake services + scene; run.sh asserts the full flow
```

## Rules for the core

1. Main thread only: poll the WebSocket in `_process`, HTTP with `HTTPRequest` + `await`. No threads.
2. The core owns HTTP, WebSocket, tokens and customer UUIDs; games never do.
3. Never log or put the runtime token in a URL; only `Authorization: Bearer`. Reads (`/events/ws`, Falcon config) send no token.
4. Inside the addon reference scripts with `preload` constants (works without the editor's class cache);
   `class_name` exists for game code.
5. Every new branch or parser gets a check in `tests/run_tests.gd`; protocol changes also in `tests/e2e/`.
6. Bump `VERSION` in `streamember.gd` and `plugin.cfg` together; add a `CHANGELOG.md` line.

## Rules for a game using it

Same as the GTA V / RDR2 mod templates: one handler per schema action (`StreamEmber.on`), amounts
`mini(cap, argument * action.quantity)`, bounded queues and alive counts, work spread over frames, everything created
removed in `live_stopped`, settings applied in `settings_changed` with the schema's paths/defaults/limits, viewer text
cut in length, schema ids never renamed after release, `tr` + `en` labels.

## Checks before done

```bash
godot --headless --path . --import
godot --headless --path . -s res://tests/run_tests.gd
GODOT=godot tests/e2e/run.sh
```
Report what passed; a passing build is not a live test with the real launcher.
