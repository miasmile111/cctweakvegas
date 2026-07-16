# cc-lua knowledge base (empirical findings)

A living wiki of things about the **CC:Tweaked runtime that you can only learn on the real
server** — behaviour that can't be tested from the PC, and cases where the actual monitor /
peripheral / redstone behaviour differs from what the docs or intuition suggest. Method
adapted from Karpathy's [llm-wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f):
the KB is a maintained artifact that compounds, not a pile of one-off war stories in the skill.

This is the **home for those findings.** The `cc-lua` SKILL.md stays the stable how-to; when
we discover a server-only quirk, it goes *here* as an entry, and the skill just points at the KB.

## When to READ it

Before building or debugging any monitor UI, peripheral, or redstone code, **skim the catalog
below** and open any entry whose `area`/tags match — these are mistakes already made and
behaviours already confirmed in-world. Don't re-derive them.

## When to WRITE to it

Add or update an entry whenever you learn something that is:

- **Server-only** — provable only against the live game (real monitor rendering, peripheral
  quirks, redstone timing, watchdog limits, multiplayer-server lag effects), OR
- **Docs-vs-reality** — the API page / your intuition said one thing, the world did another.

Do **not** log things testable in plain Lua, or that already live in the skill/docs. One
finding that reads as a small guide is fine (see `monitor-ui.md`); split it once it sprawls.

## Entry format

One finding (or tight cluster) per file, kebab-case name (`palette-dark-reads-black.md`), with:

```
---
title: <human title>
area: monitor-ui | peripheral | redstone | deploy | lua-runtime | ...
verified: in-game YYYY-MM-DD   # or: untested / docs-only — say how sure we are
tags: [ ... searchable keywords ... ]
---
```

Body: **symptom → cause → fix** (or claim → evidence → so-what). Include keywords on purpose;
this index + in-file search is the whole retrieval system. Cross-link related entries and
memories with `[[wikilink]]`.

## Create vs update

New file when it's a **distinct** quirk you'd link to from elsewhere; edit in place when it's
another facet of something already written. Keep this index's catalog in sync (one line each).

## Catalog

- [[monitor-ui]] — `monitor-ui.md` — hard-won graphics pitfalls: the "too long without yielding"
  watchdog, fractional-coord `setPixel` crash, palette animation + dark-colours-read-as-black,
  no native clipping, window+`setVisible` flicker-free draw, multi-file re-import traps, analog
  lever input. *(A bundle — draw entries out of it as they're revisited.)*
- [[deploy-and-identity]] — `deploy-and-identity.md` — code-delivery & station-identity facts:
  `wget` won't overwrite, raw-CDN 5-min cache + `?cb=` bust, rednet DNS only sees online nodes
  (→ hub is the registrar), `computerID` vs persistent label, `/disk/startup` override, chunk
  unload = reboot-fresh, Ctrl+T/`pullEventRaw` break-out, self-update-via-relaunch.
