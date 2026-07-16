---
title: Deploy & station-identity findings (GitHub pull, rednet registry, startup)
area: deploy
verified: in-game 2026-07-16 (update/hub/mkinstaller work end-to-end on Atlas)
tags: [wget, http, cache, raw.githubusercontent, rednet, lookup, host, computerID, label, disk, startup, terminate, chunk, self-update]
---

# Deploy & station-identity findings

Confirmed building the `update` / `hub` / `mkinstaller` system. The user verified the whole loop
in-world (master floppy install, auto-name, auto-run, break-out). These are the load-bearing facts.

## `wget` refuses to overwrite — use `http.get` for any updater

- `wget <url> <name>` prints `File already exists` and **quits** if the file exists (confirmed in
  CC source). It also doesn't cache-bust. So the iterate loop can't be `wget`.
- **Fix:** `http.get(url)` → `h.readAll()` → `fs.open(name,"w")`. Overwrites freely. `http.get`
  follows redirects by default (raw.githubusercontent 302s to a CDN) and handles HTTPS.

## raw.githubusercontent.com caches ~5 min — cache-bust every fetch

- After `git push`, the raw URL can serve **stale** bytes for up to ~5 min (per-IP CDN cache).
- **Fix:** append a unique query each fetch: `url .. "?cb=" .. os.epoch("utc")`. `os.epoch("utc")`
  gives a fresh ms integer (also handy for timing/timeouts). Freshness becomes immediate.

## rednet has native DNS, but `lookup` only sees ONLINE computers

- `rednet.host(proto, hostname)` advertises; `rednet.lookup(proto[, hostname])` returns the
  owner id(s) or nil. A real registry with no extra code.
- **Gotcha that shaped the architecture:** `lookup` only reaches computers **currently online and
  answering**. Idle/chunk-unloaded stations don't respond, so a peer-to-peer "what names are
  taken?" check is unreliable → **the always-loaded hub is the persistent registrar** (persists
  `computerID→{pkg:instance}` to disk, keyed by the immutable id). Idempotent = no renumber/clash.
- Every rednet user needs a **modem** + `rednet.open(peripheral.getName(modem))`.

## Computer id vs label

- `os.getComputerID()` → unique, immutable, server-assigned integer (the identity key).
- `os.setComputerLabel(str)` → friendly name, **persists across reboot** (verified: labels stuck
  through chunk reloads). Any string. This is how stations show as `slot2` / `slot2+pong1`.

## Floppy `/disk/startup` overrides the computer's own startup

- A floppy mounts at `/disk` (`disk.getMountPath`), files copyable off. A disk with `/disk/startup`
  **auto-runs on boot and takes precedence** over the computer's root `startup`. This is how the
  installer floppy self-installs on insert+reboot. `disk.getID` = unique disk id.

## Chunk unload = power off; reload = reboot + run `startup` fresh (state lost)

- Computers power off when their chunk unloads and **reboot from scratch** on reload / server
  restart — they do **not** resume mid-execution; the run position is lost.
- **Consequence:** persistence must be file-based (scores, registry), and auto-run belongs in
  `startup`. A `startup` supervisor that relaunches the game IS the self-heal for chunk churn.

## Ctrl+T / terminate & the supervisor break-out

- Ctrl+T fires a `terminate` event. `os.pullEvent` **auto-aborts** on it (invisible); 
  `os.pullEventRaw` **returns** it so you can catch it.
- **Break-out pattern:** run the game with `shell.run(prog)`; on exit, `os.pullEventRaw` in a short
  window — `key`/`char`/`terminate` → drop to shell (admin), timer → relaunch. Plus a "hold a key
  ~2s at boot" bail so a crash-looping game is still escapable.

## Self-update in one run = relaunch after overwriting

- An updater can update itself: fetch its own source, overwrite the local `update`, and if it
  changed `return shell.run("update", ...)` to re-exec the new code with the same args. Self-
  terminating: the relaunched run re-downloads identical bytes, sees no change, proceeds.

## Related

- [[monitor-ui]] — graphics-side gotchas. See also the deploy loop in the cc-lua SKILL.md and the
  spec at `docs/superpowers/specs/2026-07-16-station-identity-and-deploy-design.md`.
