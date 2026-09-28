# Changelog

*한국어: [CHANGELOG.ko.md](CHANGELOG.ko.md)*

The plugin and MuLiN Creator ship on separate channels — Creator arrives as a product
release, this plugin is pulled from this repository — so upgrading one leaves the other
where it was. Every entry below names the Creator it needs.

To see the pair you are actually running, call the `list_creator_instances` tool (or ask
the AI which Creator it is connected to): it shows this plugin's version, the Creator
version its tool list came from, and the version of every Creator window. If your Creator
is older than an entry requires, you have two moves: upgrade Creator, or check out the
plugin version that matches it (`git checkout v0.1.0`).

## 0.1.3 — 2026-09-28

**Requires a Creator 1.0.2 build from 2026-09-18 or later** — if your Creator is older than
this plugin's tool list, the AI tells you which tool it lacks.

### Changed

- You can start Claude before Creator. The tools are there from the start; if Creator isn't
  running yet the AI asks you to start it, and the next call just works — no reconnecting.
- Closing and reopening Creator no longer breaks the session. Reopen the same project and the
  AI carries on where it was.
- With several Creator windows open, the AI works in the one with your project. If it can't
  tell which, it asks you instead of guessing.
- If a Creator window is older than this plugin and lacks a tool, you are told so plainly.

### Removed

- The `check-mcp` skill. The connection no longer needs diagnosing; to see what the AI is
  connected to, ask it (it uses `list_creator_instances`).

## 0.1.2 — 2026-09-28

**Requires a Creator 1.0.2 build from 2026-09-18 or later** — earlier 1.0.2 builds have no
`inv`, `end` or `jumpn` ladder elements and reject them.

### Added

- Ladder has three more elements, and the guide now covers them. `inv` inverts the power flow
  at that point (Siemens `NOT`). `jumpn` is `jump` with the condition reversed — it jumps when
  the rung is FALSE (Siemens `JMPN`). `end` ends the current task cycle, so the programs after
  it in the same task do not run this cycle (Omron NJ/NX `End`). `inv` and `end` have no fields
  to set.
- The guide now says where each exit element belongs: `end` only in a program, `return` only in
  a function or function block. Placing either in the wrong kind of POU is accepted when you
  write it and reported by the build. `end` is not a way to leave one program early — it stops
  the rest of the task cycle as well.

## 0.1.1 — 2026-09-12

**Requires a Creator 1.0.2 build from 2026-09-12 or later** — earlier 1.0.2 builds have no
simulation tools and still report the old status fields.

### Added

- Run your project without a device. `start_simulation` starts the simulator, connects,
  builds, transfers and begins monitoring — one call does all of it, so you no longer connect,
  build and download separately. `stop_simulation` shuts it down. Both take minutes on the
  first run because the first simulator build is a clean one; later runs are incremental.
- Once simulation is running, monitoring is already on, so you can watch and write variable
  values straight away. To try a ladder change, stop and start again.

### Changed

- **The status fields changed shape, and old field names are gone.** Creator status and device
  status were mixed in one object: `connecting` and `monitoring` describe Creator, while
  `primaryConnected` and `secondaryConnected` named redundancy slots even in projects that have
  no redundancy — and in simulation, where redundancy is switched off entirely. They are now
  separate. Creator status carries `attachedTo` (nothing, a device, or the simulator),
  `monitoring` and `monitoringEdit`; each device carries a single `state` of `disconnected`,
  `connecting` or `connected`. `slot` and `role` appear only in redundancy projects rather than
  being faked as `false` elsewhere. Start a new session after upgrading so your client picks up
  the new tool definitions.
- Asking to download to a device while simulation is running now says so, and points at
  `start_simulation`, instead of reporting that you are not online — which sent you off to
  connect a device that simulation does not use.
- While simulation is starting or stopping, Creator shows a wait window and stays blocked until
  it finishes, rather than releasing after ten seconds. It used to hand the window back in the
  middle of the build, where pressing the simulation, build or download button could corrupt the
  build that was still running.
- The Creator operating guide now reads only the part it needs for what you are doing, instead
  of loading the whole thing every time — the same request now costs fewer tokens.

### Fixed

- Ladder edits made through the guide were refused while box edits went through. The guide
  named the wrong field for pointing at a contact or coil, and steered away from the element
  id that a read hands back. It now names the field the tools accept and uses that id.
- The guide did not say that `delete_pou` answers its own confirmation dialog, or that
  deleting a C++ POU removes its source folder with no way back. It now says both, before
  you call it.
- A malformed address or initial value on a variable was described as accepted. It is
  dropped instead, and the build does not catch it — the variable ends up bound to nothing
  and the device does not drive the I/O you expected. The guide now tells you to read back
  what was actually stored.
- Reading project settings was described backwards: leaving out `depth` returns the whole
  tree, not a list of child names. The guide now says how to ask for either.

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
