---
name: engineering
description: "Use when operating MuLiN Creator via MCP tools: the sequence for opening a project, editing POUs/ladder/variables/tasks, building, and downloading to a device, plus where this tool set actually gets stuck. Read before touching ladder, or when a tool rejects with creator.busy."
---

# Operating MuLiN Creator

These tools operate a running Creator window **the same way a person operates the GUI.**
They pass through the same widgets, the same undo stack, and the same validation, so they
hit exactly what a person hits — dialogs pop up, editing is blocked while monitoring, and
unsaved work disappears.

**The tool descriptions and error responses are the source of truth for arguments and
error codes.** This document covers only the **sequence and risks** that those don't.

## Getting started

1. `get_creator_status` — which window, whether a project is open, whether monitoring is
   active. **Whenever you feel stuck, come back here.**
2. `open_project` or `create_project`
3. `list_pous` → `open_page` (path form `/pou/prg|fc|fb/<name>`) — **some tools only work
   while the editor is open.** This is the setup step before touching ladder or adding
   variables.
4. Make the change → **`save_project`**

`get_project_status` answers "is it open, has it been modified, what project is this"
(identity); `get_object_data` answers "what is it set to" (a value reached by path) —
don't confuse the two.

## Where this actually gets stuck

**Monitoring.** Ladder edits are rejected while monitoring is active. Call
`stop_monitoring` first, and **do not forget `start_monitoring` afterwards** — the user was
watching that screen.

**Time.** `build_project` and `download_to_device` don't respond until they finish — on
the order of minutes. Calling them again because they seem slow just runs the same job
twice.

**The device.** `download_to_device`, `start_plc`, `stop_plc`, and `reset_plc` **change
real equipment.** If the user hasn't directed it on the spot, **ask first.** A download to
a device that is running is refused, not half-applied; the irreversible moment is the other
side — **a successful download can put the device into RUN by itself**, and a running PLC
moves physical outputs.

**Deleting a POU.** `delete_pou` answers its own confirmation dialog — nobody gets a second
look. For a C++ POU it takes the `Cxx/<name>/` folder with it, hand-written `.cpp`/`.h`
included, and **these tools have no way to put it back.** If the user didn't ask for it on
the spot, **ask first** (`references/pou.md`).

**Closing a page.** `close_page` is a **commit, not a discard** — it writes that page's
content into the model without asking. Reaching for it to throw an edit away produces the
opposite of what you wanted.

**Dialogs.** A `creator.busy` rejection means one is open — see "When a dialog blocks
you" below.

## Rules you must follow

- **Call `save_project`.** Writes made through this contract only reach the window's
  in-memory model.
- **Don't invent paths or names.** Get them from `list_pages`, `list_pous`, `list_duts`,
  `list_variables`, `list_instructions`. A nonexistent instruction name isn't rejected
  when you put it into ladder — it blows up at build time instead. If you're not sure, use
  `search_manual`/`read_manual`.
- **Before writing, read `get_object_data` once with `schema: true`.** There's no other
  way to learn the range (`min`/`max`) and the allowed enum values (`options[].value`) —
  guessing from the header data type gets it wrong (task priority looks like it caps at
  255 from the data type alone, but the real limit is 31).
- **Expand `error.detail.errors[]` on failure.** The top-level
  code is generic — `data.invalid`, `dut.invalid`, `data.invalid_value` (wrong value, not
  shape — an unknown enum member, a bad IPv4/version string) — the real reason is collected
  per-path in that array.
- **Don't add fields you don't recognize.** Ladder and DUT tools reject any field outside
  the allowed list with `params.invalid` — this is so a typo can't silently succeed.
  Writing back exactly what you read is always safe.
- **Omitting a key and giving an empty string mean different things.** Omitting means
  "leave it as is"; an empty string means **"clear it"** (for label, comment, initial
  value, address, parameter value). Two exceptions — `dataType` and `array` can't be
  cleared with an empty string and are rejected instead, and an enum member's `value`
  isn't cleared but renumbered to one past the highest value among the members before it
  (so 0 for the first member).
- **Read the response's `warnings`.** This contract reports several kinds of bad input as
  a warning rather than a rejection, so a call that reports success can still be wrong.
- **Don't give `namespace` a value.** Five tools
  (`add_dut`·`update_dut`·`add_pou`·`add_variable`·`update_variable`) carry it in their
  schema, but any value is rejected with `namespace.unsupported`. Omit it, or pass an
  empty string. **Don't qualify names either** — what you create lands in the global scope
  and only built-in elements live inside `Mulin`, so a bare name is never ambiguous.
- **One call is one unit.** Even when a call spans several nodes or members, if any one of
  them fails validation **nothing at all is written** — nothing is left half-changed.
  Failure doesn't stop at the first item either; it is collected per path, so read the
  whole array.
- **Assume a write can't be undone — `before` is the way back.** Most of these tools don't
  reach the undo stack (`update_object_data`, the DUT tools, and the POU and task tools
  among them), so **never tell the user Ctrl+Z will bring it back.** A successful response
  hands you the prior value as `before`, and sending it back is the only way to revert.
  **Its shape, and which tool you send it back to, differ per target — the reference file
  for that target says both.** For `update_object_data` it arrives as
  `changed[] = {path, before, after}`, one entry per key that changed, next to `unchanged`
  — the keys that already held the value you sent, which is not a rejection. **Ladder is
  the one group that does reach the undo stack** — `*_ld_*` writes carry no `before` at
  all, because Ctrl+Z is the way back there (`references/ld.md`).

## When a dialog blocks you

Tools already drive every dialog they know about, so a normal MCP-only session rarely sees
one. When one does appear, every call rejects with `creator.busy` until it is answered.

1. `list_dialogs` — what is open and what it is asking.
2. `set_dialog_field` / `click_dialog_button` — answer it.
3. Retry the original call; it now proceeds.

This trio matters most for a **different** Creator window stuck behind a dialog — a
crash-recovery prompt, for instance — while a person works the window you're attached to.
`list_creator_instances` lists every detected window including that one (it has no project
open yet, so its `projectPath` comes back empty). Pin to it with `use_creator_instance`,
close the dialog, and the session is no longer stuck between two windows with no way to
choose.

## When the attached window changes

This bridge pins itself to one Creator window the first time it connects, and keeps
talking to that exact process (matched by port and pid) for the rest of the session. If
that window closes and a *different* Creator answers on retry, the bridge does not
silently start talking to it — the call fails with `creator.instance_changed` instead of
being applied to a window you didn't choose.

1. Read `error.detail.candidates` in that response — every Creator this bridge can
   currently see, with `port`, `pid`, `projectPath`, and whether it answers a ping.
2. Call `use_creator_instance` with the `port` of the one you want. This re-pins the
   session in place — no new session, no `/mcp` reconnect.
3. Retry the call that failed.

This is a different situation from the "multiple candidates" rejection
`/mulin-creator:check-mcp` describes below — that one happens *before* this bridge has ever
attached to anything, and its fix is still `MULIN_MCP_PORT` plus a fresh session.
`creator.instance_changed` only happens *after* a successful attach, mid-session, and its
fix (`use_creator_instance`) needs no restart at all.

## When you can't connect

Run `/mulin-creator:check-mcp`. It pinpoints whether Creator is closed, whether there are two
windows and it couldn't tell which one, or whether a stale lock file was left behind.

## Where the rest of this lives

This file is the whole of what always applies. Everything else is loaded on demand —
**read the file before the first call in that group, not after it fails.**

| Before you | Read | What skipping it costs |
|---|---|---|
| do anything with pages — always, once per session | `references/pages.md` | You guess a path, or hand the user a key instead of a name. |
| touch a POU (`*_pou*`) | `references/pou.md` | You ask the wrong tool for a box's pins and misread `pou.not_found`. |
| declare or read a variable (`*_variable*`, `*_watched_values`) | `references/variable.md` | You report a pulse as absent that the sampling period simply never saw. |
| call any `*_ld_*` tool | `references/ld.md` | A bad layout gets accepted here and fails at build time. |
| call any `*_dut*` tool | `references/dut.md` | You send `before` to a tool that rejects half its fields. |
| call `get_object_data`/`update_object_data` | `references/settings.md` | You write the switch and its settings in one call and get `data.unavailable`. |
| touch a task (`*_task*`, `*_prg_*task`) | `references/tasks.md` | You hunt for one tool that does structure and values at once. |
| build, download, or touch the device (`build_project`, `*_to_device`, `*connect_device`, `*_device_status`, `*_plc`, `*_monitoring`, `*_simulation`) | `references/device.md` | You act on equipment without establishing which equipment it is. |
