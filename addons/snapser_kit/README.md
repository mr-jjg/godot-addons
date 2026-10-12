# Snapser Kit

A game-agnostic [Snapser](https://snapser.com) client for Godot 4.x. It provides:
- config resolution
- anonymous auth with account linking
- a hardened HTTP transport
- typed snap clients
- local-first cloud save
- one base class, `SnapKitService`, that a game's `Snapser` autoload extends

Web-safe: it uses no threads.

**The client never uses an API key.** The gateway authenticates each player with a session (`Token` / `User-Id` headers) from anonymous or provider login. Platform keys belong to `snapctl` and server tooling only.

## Install

1. Copy `addons/snapser_kit/` (and `addons/editor_tool_kit/`, for self-update) into the game's `addons/`. Enable the plugin.
2. Commit `res://snapser_kit.config.json`. It contains no secrets:
   ```json
   {
     "game_id": "mygame",
     "gateway_url": "https://gateway.snapser.com/<snapend-id>",
     "anon_handle_prefix": "mygame-",
     "leaderboards": { "career_wins": "career_wins" },
     "cloud_save": { "blob_key": "save_v1", "sync_prefixes": ["sax_prog_"], "sync_keys": ["sax_militia_unlocked"] },
     "link_providers": ["apple"],
     "quests": false,
     "offline_paths": ["res://tests", "res://tools"],
     "declared": {
       "stats": ["hits"], "boards": ["career_wins"],
       "events": ["session_start", "session_end", "online_state", "run_start", "run_end", "screen_view"],
       "blobs": ["save_v1"]
     }
   }
   ```
3. Add the autoload `Snapser` → `res://scripts/snapser.gd`:
   ```gdscript
   extends SnapKitService
   func _ready() -> void:
       start()
   ```

## Connection resolution

The first matching rule wins:
1. `SNAPSER_OFFLINE=1` or `--snapser-offline` forces offline. Tests and capture runs use this.
   - **Test, tool and headless runs are offline automatically, and the check fails closed.** A run counts as one when:
     - it's a `--script` / `-s` run;
     - a scene or script on the command line, or the main scene, lies under one of `offline_paths`. Paths are normalised first, so `res://`, relative, absolute and `uid://` forms all count. The default is `["res://tests", "res://tools"]`; set `"offline_paths"` in the config to replace the list, e.g. add `"res://scenes/tools"`;
     - the process is **headless**.

     Set `SNAPSER_TESTS_ONLINE=1` to opt a live end-to-end test back in.
   - At runtime, `Snapser.force_offline(reason)` switches the kit offline, for example from a settings toggle. On a bare config, use `SnapKitConfig.force_offline(reason)`.
   - **Offline and test runs write nothing under `user://`:** no session file, no cloud-save state file. That bookkeeping stays in memory until the kit is online.
2. The `SNAPSER_GATEWAY_URL` environment variable.
3. `user://snapser_kit.override.json` (`{"gateway_url": …}` or `{"offline": true}`), read in **debug builds only**.
4. The committed `gateway_url`.
5. If none of these resolves, the game runs offline.

## The API (`SnapKitService`)

Every network call:
- is a coroutine (`await`);
- returns at least `{ok, error}`;
- **never throws**.

When offline, every call returns `{ok:false, error:"offline"}` immediately, so gameplay code never branches on connectivity.

| Area | Calls |
|---|---|
| Status | `is_online()`, `user_id()`, `await wait_until_ready()` (returns online state after boot), `force_offline(reason)`. `is_online()` is **false until boot has logged in**, so screens that check it in `_ready()` should `await Snapser.wait_until_ready()` first. |
| Signals | `online_changed`, `session_ready`, `config_updated`, `cloud_save_conflict`, `cloud_save_applied(keys)`, `boot_finished` |
| Stats | `record_stat(key, value)`, `increment_stat(key, delta)` (keys `^[a-z0-9_]+$`) |
| Leaderboards | `submit_score(board, score)`, `top_scores(board, n)`, `scores_around_me(board, n)` (boards map through `config.leaderboards`) |
| Remote config | `remote_config()` (cached), `refresh_remote_config()` |
| Cloud save | `cloud_save_push()`, `cloud_save_pull()`. Override `_merge(local, remote)`. The default merges bools with OR, numbers with max and arrays with union; anything else takes the newer value. Set `save_store` (duck-typed `export_prefix` / `import_prefix` / optional `changed` signal) or rely on `/root/SaveService`. After a pull or merge, `cloud_save_applied(keys)` lists what changed locally; refresh caches from it. Synced keys are those under `sync_prefixes` plus the exact names in `sync_keys`. **Bools are monotonic progress flags on every pull path:** a `true` on either side stays `true`, even when only the remote changed. Per-key overrides go in `cloud_save.merge_policy`: `{"<key>" or "<prefix>*": "max" | "or" | "remote" | "local"}`. For example, `"sax_set_tutorial_seen": "remote"` opts a flag out. A pull adds and overwrites exact keys but never deletes them, and never touches siblings that merely start with the same text. |
| Analytics | `track(event, props)`: queued and batched; never blocks. The kit sends `session_start`, `session_end` and `online_state` itself. |
| Profile | `display_name()` (never empty), `set_display_name(name)`: trims, length-limits (3–16) and filters. Names are **not unique** (D33). |
| Identity | `register_identity_provider(name, bridge)`, `link_account(provider)`, `switch_account(result)`, `linked_providers()`. Linking is **off** unless `link_providers` lists the provider; `[]` returns `disabled` (D35). |
| Quests | `quests_fetch_active/assign/increment/claim` (requires `"quests": true`) |
| Debug & inspection | `debug_snapshot()`, `fetch_stats()`, `cloud_save_fetch_remote()`, `cloud_save_force_push()`, `cloud_save_force_take_remote()`, `cloud_save_simulate_new_device()`, `cloud_save_delete_remote()`, `debug_login_anon(handle, mode)`, `debug_return_to_primary(mode)`, `debug_identities()`. See [Debug & inspection (0.3.0)](#debug--inspection-030). |

Lower layers are public for advanced use:
- `config` (`SnapKitConfig`)
- `auth` (`SnapKitAuth`)
- `transport` (`SnapKitTransport`)
- `*_client` (`SnapKitStats`, `SnapKitLeaderboards`, `SnapKitStorage`, `SnapKitRemoteConfig`, `SnapKitQuests`, `SnapKitProfiles`, `SnapKitAnalytics`)
- `cloud_save` (`SnapKitCloudSave`)

### Transport contract

`await transport.request(method, path, body = null, opts = {})` always returns `{ok, status, json, error}`.

- **Paths** are gateway-relative and may contain `{user_id}`, which is filled in after the session is ensured.
- **opts:**
  - `auth` (default true)
  - `timeout_s` (default 10)
  - `retries`: default 2 for GET/PUT/DELETE, 0 for POST/PATCH. Retries happen only on timeout, network errors, 429 and 5xx, with jittered backoff.
  - `headers`
  - `no_retry`: disables both the retries and the 401 replay.
- **On a 401** the transport re-logs in once (same anonymous user) and replays once.
- **Errors:** every result carries `error` (a kit code) and `snap_code` (Snapser's `api_error_code`, 0 when absent).
  - Transport codes: `offline`, `no_session`, `timeout`, `network`.
  - Named Snapser codes (`SnapKitErrors`): `undeclared` (also stat 4000 / event 2000), `quest_not_claimable` (15014), `cas_conflict` (5007), `already_exists`, `not_found`, `invalid_property_value`, `anon_login_disabled`.
  - Otherwise `http_<status>`.
  - Client-level codes: `bad_response`, `invalid_argument`, `disabled`, `not_implemented`.

### Whose progress wins (D36)

| Situation | Result |
|---|---|
| **First sync** on a device (including progress from before Snapser) | Merged; local progress is **never discarded**. |
| **Linking a NEW provider account** (`link_account` → ok) | The provider login joins the current anonymous user, so nothing changes and nothing is lost. |
| **Switching to an EXISTING account** (`link_account` → `account_exists` → `switch_account`) | **The account wins.** Its cloud save replaces local synced data for every key, except bools, which OR: guest achievements and unlocks survive. Guest-only non-bool progress (wins, coins, levels) is dropped and listed in `result.cloud_save.dropped`. If the account has no save, only the guest's `true` flags are kept. |
| Ordinary pulls afterwards | Monotonic bools plus the normal merge or take-remote rules. `merge_policy` applies. |

Cloud-save bookkeeping (CAS token, version, `has_synced`) is **per user**. It's reset whenever the session user changes (`switch_account`, sign-out, a different login), so a switched session never reuses the previous user's state. Only the device id survives. Tell players before they switch: "This device will load your account's progress."

### Rolling out linking (D35)

1. Ship with `"link_providers": []`. `link_account()` returns `{ok:false, error:"disabled"}` and never opens a platform sheet.
2. Enable **Sign in with Apple** on the App ID in the Apple Developer console **first**.
3. Only then add the `com.apple.developer.applesignin` entitlement (see `snapser_kit_apple`). **An entitlement without the App ID capability breaks cloud signing**, so the TestFlight build fails to sign.
4. Configure the Apple connector on the snapend. This is a post-ship apply, so it needs approval (D8).
5. Set `"link_providers": ["apple"]` and ship.

### ⚠ `cloud_save_applied`: refresh game state before anything saves

A pull or merge writes straight into the save store, while the game's in-memory state (unlocked modes, achievement caches, registries) still holds the old values. Refresh that state from the store **synchronously, inside the `cloud_save_applied(keys)` handler**, before anything can call a save. If the game saves its stale in-memory copy first, it overwrites the pulled data, and the next sync propagates the loss. This is the theo-asteroids failure mode: a remote `false` re-locked an earned mode until it was fixed in 0.2.1.

### Declarations

Snapser rejects undeclared stat keys, events, boards and storage keys with a 404. List them under `"declared"` in the config. A kind you leave out isn't checked.

- **Debug builds:** `record_stat`, `increment_stat`, `submit_score`, `cloud_save_*` and `track` on an undeclared name log one warning and return `{ok:false, error:"undeclared"}` (events are dropped). There's no network call, even when offline, so offline tests catch typos.
- **Release builds:** the kit warns once and sends anyway.

Keep the section in step with the snapend: `tools/snapser/check_declarations.sh <game repo>`, or `SnapKitConfig.from_dict(cfg).declaration_problems(manifest)` in a headless test.

## Debug & inspection (0.3.0)

These calls back a game's in-game save and account tools: inspect the cloud-save bookkeeping, diff local against remote, force either side, replay a fresh install, and switch to a second anonymous identity to exercise a real account switch without platform sign-in.

### The gate

- **Read-only calls are ungated:** `debug_snapshot()`, `fetch_stats()`, `cloud_save_fetch_remote()`, `debug_identities()`, and the pure `SnapKitCloudSave.diff_rows()`.
- **Mutating calls need `debug_tools_enabled`.** Otherwise they return `{ok:false, error:"debug_disabled"}` and send nothing. It defaults to `OS.is_debug_build()`. Set it from the game's own build policy **before `start()`**; the setter also flips `cloud_save.debug_tools_enabled`.
- Every network call still passes the usual gate first. Offline answers `offline` at once, and an undeclared blob answers `undeclared`. For the `cloud_save_*` calls the order is: service gate, then cloud save enabled (`disabled`), then the debug gate.

### Calls

| Call | What it does |
|---|---|
| `debug_snapshot(with_local = true)` | Not a coroutine. `{online, booted, offline_reason, user_id, handle, linked, switched, debug_tools, primary_handle, cloud_save}`. `cloud_save` is `SnapKitCloudSave.debug_snapshot()`: `enabled, user_id, device_id, blob_key, access, has_synced, cas, version, synced_hash, synced_at, local_changed_at, dirty, busy, debounce_left_s, persisted, state_path, prefixes, sync_keys, merge_policy`, plus `local_hash` and `local_matches_synced` when `with_local`. Pass `false` to skip `export_local()`, since some stores flush on export. |
| `fetch_stats()` | `{ok, error, stats:{key:int}}`: every stat the user holds (`GET /v1/statistics/settings/user-stats/{user_id}`). |
| `cloud_save_fetch_remote()` | The blob as stored: `{ok, error, exists, cas, version, updated_at, device_id, data, hash}`. Waits for any running sync and changes nothing. |
| `cloud_save_force_push()` | **Local wins exactly.** The remote becomes the local synced keys: no merge, no bool OR, remote-only keys disappear. It writes `version + 1` with the current CAS, retries a CAS race, and records the sync, so the next push is skipped. Returns `applied:"forced_local"`, `version`, `replaced` (the keys that changed remotely) and `conflict` (a race was met). |
| `cloud_save_force_take_remote()` | **Remote wins exactly.** The local synced keys become the blob: no merge, no bool OR, no `merge_policy`. Local-only keys are removed when the store's `import_prefix` takes `replace`; `exact` is false when it doesn't. No blob gives `not_found` and changes nothing. It records the sync, so the next pull is `none`, and fires `cloud_save_applied`. Returns `applied:"forced_remote"`, `keys`, `dropped`, `exact`. |
| `cloud_save_simulate_new_device()` | A fresh install of the **same** account. It wipes the local synced keys, forgets the bookkeeping, mints a new device id, then runs the normal first-sync pull, which takes the remote. Returns the pull's result plus `wiped`. `cloud_save_applied` fires for the wipe and again for the restore. |
| `cloud_save_delete_remote()` | Deletes the user's blob and resets the bookkeeping, so the next sync is a first sync. A blob that is already gone is `ok` with `existed:false`. |
| `SnapKitCloudSave.diff_rows(local, remote, policies, remote_is_newer)` | Static and pure. One row per key, sorted: `{key, status ("same", "local_only", "remote_only", "differs"), policy, local, remote, merge, take, account}` plus an `in_*` flag for each value column (an absent value is `null`). `merge` previews a both-changed pull, `take` a remote-only-change pull, and `account` a `switch_account`. A game that overrides `_merge()` still sees the **default** merge here. |
| `debug_login_anon(handle = "", mode = "account")` | Becomes the anonymous user `handle`; `""` mints a fresh handle with the config's prefix. This stands in for signing in to another account on this device. The first call records the current handle as the **primary**, before switching. `mode`: `"account"` applies the real switch rule (D36, as `switch_account`), `"pull"` runs a normal first sync (merge), `"none"` swaps the session only. Returns `{ok, error, user_id, handle, previous_user_id, cloud_save?, warning?}`. |
| `debug_return_to_primary(mode = "account")` | `debug_login_anon(primary, mode)`. Returns `no_primary` when none was recorded. |
| `debug_identities()` | Not a coroutine. `[{handle, user_id, primary, current, created_at}]`, primary first. |

A debug identity is a real anonymous login (`SnapKitAuth.login_anon_as()`): the handle is persisted and the session is not marked switched, so a lost session heals by anonymous re-login as that identity. `SnapKitAuth.is_switched()` reports an adopted provider session.

### Caveats

- **A revoke needs a force push, and another device ORs it back.** Bools are monotonic on every pull path, so a flag cleared locally comes back on the next sync while the blob still holds `true`. `cloud_save_force_push()` clears the blob, but any other device that still holds `true` restores it on its next pull.
- **The identities file** is `snapser_kit_debug_identities.json` under `SnapKitConfig.data_root` (`debug_identities_path`). Like the cloud-save state file, it is written only while the config is online. It holds the primary handle. If it is lost while a debug identity is active, the session file holds only the debug handle and **the primary is gone**: nothing on the device can log back in as it. For a dev user that is cheap; show the primary handle in the tool so it can be noted.
- **Leaving a provider account.** From an adopted provider session (`is_switched()`), `debug_login_anon` proceeds but adds `warning`. Only a new provider sign-in returns to that account; the recorded primary is the device's old anonymous handle.
- **Queued analytics** are flushed as whichever user holds the session at flush time, so events queued just before a switch are attributed to the new user. That's acceptable for a debug-only path.

## Version notes

- **0.3.0**: debug and inspection APIs (above): `SnapKitCloudSave.debug_snapshot`, `fetch_remote`, `force_push`, `force_take_remote`, `simulate_new_device`, `delete_remote`, `diff_rows`; `SnapKitAuth.is_switched`, `login_anon_as`; `SnapKitService.debug_tools_enabled`, `debug_snapshot`, `fetch_stats`, the `cloud_save_*` debug wrappers and the debug anonymous identities. Existing behaviour is unchanged.

## Editor

Project → Tools has two items:
- **Snapser Kit: Show resolved config**
- **Snapser Kit: Test connection** (anonymous login, using its own probe session)

## Tests

```bash
SNAPSER_OFFLINE=1 godot --headless --path . --script res://tests/snapser_kit/run_tests.gd [-- --filter=<substr>]
```

- Tests live in `tests/snapser_kit/` in the godot-addons repo.
- They use `SnapKitMockGateway`, an in-process fake gateway with anonymous login and refresh, 401 simulation and failure injection. They never touch the network.
- **Files go in a sandbox:** every file the kit writes (session, cloud-save state, editor probe) lives under `SnapKitConfig.data_root`, which defaults to `user://`.
  - The test runner, and any `SnapKitMockGateway` you construct, move it to a scratch directory, so tests never touch a player's real files.
  - The runner fails the suite if anything under `user://` changes.
  - A game's own suites can do the same by calling `SnapKitMockGateway.use_scratch_data_root()` before starting the service.
- Live smoke tests and provisioning are covered in `tools/snapser/RUNBOOK.md`.
