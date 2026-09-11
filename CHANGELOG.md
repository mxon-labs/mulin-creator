# Changelog

*한국어: [CHANGELOG.ko.md](CHANGELOG.ko.md)*

The plugin and MuLiN Creator ship on separate channels — Creator arrives as a product
release, this plugin is pulled from this repository — so upgrading one leaves the other
where it was. Every entry below names the Creator it needs.

To see the pair you are actually running, run the `mulin-creator:check-mcp` skill. Its first line
is this plugin's version; section 2 lists the version of every Creator window it can reach.
If your Creator is older than an entry requires, you have two moves: upgrade Creator, or
check out the plugin version that matches it (`git checkout v0.1.0`).

## 0.1.0 — 2026-09-11

**Requires a Creator 1.0.2 build that reports the `instance` field** — the version number
alone does not tell you: 1.0.2 builds from before this change do not carry it.

### Added

- First release. An AI client can open your projects and work through POUs, ladder networks,
  variables and tasks, then build and download to a device.
- Claude Code and Codex both install it from this repository. Register the marketplace, then
  add the plugin, and the tools and both skills arrive together.
- The bridge waits up to 30 minutes for a Creator window to appear and attaches to the first
  one it finds, so the order you start things in does not matter. Restarting Creator
  mid-session needs no action either — the next tool call reconnects on its own.
- `list_creator_instances` and `use_creator_instance` show every Creator window the bridge
  can detect and switch which one the session talks to without restarting, including a
  window still stuck behind a dialog.
- Every tool response names the Creator instance (port, pid) that answered it. If the window
  this session was talking to closed and a different one started answering in its place, the
  call fails with `creator.instance_changed` rather than writing to the wrong window.
- `mulin-creator:check-mcp` reports the plugin version and the Creator versions side by side,
  so you can tell at a glance whether the two are a matching set.
- `mulin-creator:engineering` carries the operating sequence — what a ladder actually is,
  what to do when a dialog blocks a call, and where this tool set gets stuck.
