# Station identity & deploy system — design

**Date:** 2026-07-16
**Status:** approved, pre-implementation
**Depends on / feeds:** the hub-authoritative economy in `README.md` (this builds the hub's
first brick — the registrar).

## Problem

Getting code onto stations was manual (gist → `wget`, delete-first, stale-cache traps). And
with 10+ computers on the floor, bare numeric computer IDs are meaningless — we want friendly,
collision-free names (`slot2`, `pong1`) assigned automatically. Setting up a new station should
be near-zero-effort.

## Goals

1. **One-command update** — `update slot` pulls that package's files fresh from the repo.
2. **Auto-identity** — installing a package assigns the computer a unique, human-readable label
   (`slot2`), collision-free across the whole floor, idempotent on re-run.
3. **Floppy setup** — a new station = drop computer + disk drive + modem, insert an installer
   floppy, reboot → self-installs, self-registers, self-names. Pull the floppy; the drive is now
   free for member cards.

## Confirmed CC:Tweaked facts (verified against tweaked.cc, 2026-07-16)

- `os.getComputerID()` → unique, immutable, server-assigned integer. The identity key.
- `os.setComputerLabel(str)` → friendly name, any string, persists across reboot.
- `rednet.host(proto, name)` / `rednet.lookup(proto[, name])` → native name registry; lookup
  returns owner id or nil. **Caveat:** only sees computers *currently online* — unreliable alone
  because idle/chunk-unloaded stations don't answer. Hence a persistent registrar (the hub).
- Floppy mounts at `/disk` (`disk.getMountPath`); files copyable off; `disk.getID` unique per disk.
- A disk with `/disk/startup` auto-runs on boot and **overrides** the computer's own startup.
- rednet requires a modem (wired modem also frees computer sides — existing convention).

## Architecture

Four components.

### 1. Package manifest (repo-side) — `src/packages.lua`

Maps a package name to its file list. `update` fetches this from the repo, then pulls the files.

```lua
return {
  slot = {
    station = true,                       -- needs an instance ID/label
    files = {
      { name = "subpixel", path = "lib/subpixel.lua" },
      { name = "slot_logic" }, { name = "slot_symbols" }, { name = "slot" },
    },
  },
  hub = { station = false, files = { { name = "hub" }, { name = "packages" } } },
  -- pong, etc.
}
```

`path` defaults to `<name>.lua` under `src/`. `station = true` means installing it triggers
identity registration; infra like `hub` sets it false.

### 2. `update.lua` (station-side)

`update <pkg> [<pkg> ...]`:

0. **Self-update** — re-pull `update.lua` and drop a fresh copy onto this computer (non-fatal).
   Bugfixes to the updater propagate for free, and running it straight off a master floppy
   (`/disk/update slot`) plants a local `update`.
1. Fetch `packages.lua` from the repo (cache-busted `?cb=<epoch>`), pull each requested
   package's files via `http.get`, overwrite locally (no `wget` delete dance).
2. Record installed packages locally (`.installed` file).
3. For each installed `station = true` package: **register** with the hub (below) to get an
   instance number, accumulate into the label.
4. `os.setComputerLabel(...)` — join instances with `+`, e.g. `slot2+pong1`.

4. **Enable auto-run** (station packages) — write a `startup` on the computer (marked, won't
   clobber a foreign one) + a `.station` file naming the program. On every boot it launches the
   game under a **supervisor** that self-heals (relaunch on crash/terminate/chunk-reload) with
   three admin escape hatches: hold a key ~2s at boot, Ctrl+T during the game, or a key in the
   3s post-exit window → drops to shell. Runs whether or not registration succeeded.

   **Lag dependency:** auto-run is only safe at scale once each game honors the README idle
   model (deep-sleep on `os.pullEvent`, wake on a proximity plate). `slot.lua` currently
   animates continuously — implement idle-sleep before mass-deploying auto-run.

**Preflight (fail loudly):**
- **Hardware = hard requirement.** No disk drive or no wired modem → print a loud banner
  (`I need a disk drive and wired modem!`) listing what's missing, and **stop** — install nothing.
  A station without them is not a valid station.
- **Hub offline = install-soft, warn-loud.** Hardware present but hub unreachable → still install
  the files and enable auto-run, but print a prominent `REGISTRATION FAILED — HUB OFFLINE` banner:
  the station has NO NAME and won't be tracked until the hub is up and `update` is re-run. Files
  install so the game is playable unnamed; only the identity step fails, and it fails loudly.

### 3. Hub v0 — the registrar — `src/hub.lua`

A rednet service in an always-loaded chunk. The single arbiter of station identity.

- On start: `rednet.open(<modem side>)`, `rednet.host("ccvegas", "hub")` so stations find it.
- Persists an assignment table to disk (`registry.tbl` via `textutils.serialize`):
  ```lua
  {
    assignments = { [47] = { slot = 2 }, [12] = { slot = 1, pong = 1 } },  -- computerID -> {pkg: n}
    counters    = { slot = 2, pong = 1 },                                  -- highest n per pkg
  }
  ```
- Handles `register` requests (protocol `ccvegas`):
  - Request: `{ kind = "register", computerID = N, package = "slot" }`.
  - If `assignments[N].slot` exists → reply that same number (**idempotent** — re-running
    `update` never renumbers, never collides).
  - Else `counters.slot = counters.slot + 1`, store, persist, reply the new number.
  - Reply: `{ kind = "assigned", package = "slot", instance = 2 }`.
- This registry is the seed of the hub-authoritative economy: the hub now knows every station.

### 4. `mkinstaller.lua` + install floppies

`update.lua` is fetched from the web **once** (here) and carried on a floppy thereafter. Two modes:

- **`mkinstaller`** (no args) → a **master tools floppy** (label `cctweak:tools`) carrying
  `update`. On any new computer, run it straight off the disk: `/disk/update slot`. Self-update
  (step 0) plants a current `update` locally. Reused forever; the one web fetch never repeats.
- **`mkinstaller slot [pong]`** → an **auto-install floppy** (label `install:slot`): `update` +
  a `pkg` file + a `/disk/startup` that copies `update` to the host, runs `update <pkgs>`, and
  self-registers. New-station flow: computer + disk drive + modem, insert floppy, reboot →
  auto-install + auto-name → remove floppy → drive free for member cards.

## rednet protocol (v0)

Protocol string: **`ccvegas`**. Discovery: hub hosts hostname `hub`; stations
`rednet.lookup("ccvegas", "hub")`.

| From → To         | message                                                        | reply                                                    |
| ----------------- | ------------------------------------------------------------- | -------------------------------------------------------- |
| station → hub     | `{ kind="register", computerID=N, package="slot" }`           | `{ kind="assigned", package="slot", instance=2 }`        |
| (future) → hub    | `{ kind="credit", id="neon_max", delta=50 }`                  | ack                                                      |
| (future) → hub    | `{ kind="query", id="neon_max" }`                             | `{ kind="balance", id="neon_max", score=1450 }`          |

Only `register` ships in v0; `credit`/`query` are the economy, listed so the hub's dispatch is
built to extend.

## Station bill of materials (falls out of this)

Every station: **computer + disk drive** (member cards) **+ wired modem** (rednet + monitor over
the network). Documented so the hub floor plan accounts for it.

## Out of scope (v0)

Member-card read/write, the credit/query economy, scoreboards, security. This spec is identity +
deploy only; the economy plugs into the same hub + protocol next.
