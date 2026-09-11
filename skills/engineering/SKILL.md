---
name: engineering
description: "MuLiN Creator를 MCP 도구로 조작할 때 — 프로젝트를 열고 POU·래더·변수·태스크를 고쳐 빌드·다운로드하는 순서와 실제로 막히는 지점들. 래더를 만지기 전, 도구가 creator.busy로 거절할 때 읽는다. / Use when operating MuLiN Creator via MCP tools: the sequence for opening a project, editing POUs/ladder/variables/tasks, building, and downloading to a device, plus where this tool set actually gets stuck. Read before touching ladder, or when a tool rejects with creator.busy."
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
`stop_monitoring` first, and **do not forget to turn it back on** — the user was watching
that screen.

**Time.** `build_project` and `download_to_device` don't respond until they finish — on
the order of minutes. Calling them again because they seem slow just runs the same job
twice.

**The device.** `download_to_device`, `start_plc`, `stop_plc`, and `reset_plc` **change
real equipment.** If the user hasn't directed it on the spot, **ask first.** Downloading
to equipment that's running cannot be undone.

**Dialogs, briefly.** Tools already drive every dialog they know about — adding a POU,
renaming a variable, deleting a global — so a normal MCP-only session rarely sees one. A
`creator.busy` rejection means one is open: check it with `list_dialogs`, answer with
`set_dialog_field`/`click_dialog_button`, then the original call proceeds. This trio matters
most for a **different** window stuck behind a dialog while a person works the one you're
attached to — see "When the attached window changes" below.

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
- **Expand `errorDetail.errors[]` / `error.detail.errors[]` on failure.** The top-level
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
  isn't cleared but renumbered to max + 1.

## Pages — the path is the address

`path` follows the project browser's structure, but **each segment is a fixed key that
isn't localized.** The name shown on screen comes back separately as `title` — **use
`title` when talking to the user, `path` when calling a tool.** Get it from `list_pages`;
when pruning with `under`, it cuts **only at segment boundaries** (`under: "/pou"` does
not match `/pouX`). **Anything that appears in the list is guaranteed to open** — that's
an invariant of this contract.

| Path | |
|---|---|
| `/projectProperty` · `/globalVariable` · `/systemVariable` · `/addressComment` | Single page |
| `/dut/struct\|enum\|typedef/<name>` | System data types live in the same place |
| `/pou/prg\|fc\|fb/<name>` | Doesn't distinguish LD from C++ POUs |
| `/task/configuration` · `/task/monitoring` | |
| `/controller/operation` · `/controller/configuration` | configuration only exists when the CPU is a TOP/MIO series |
| `/externalDevice/<name>` | |
| `/redundancy` · `/redundancy/operation` · `/redundancy/configuration` | All three exist only when redundancy is turned on |

- `open_page` opens **in a background tab by default** (it doesn't steal the tab the
  person was looking at). To bring it forward, pass `focus: true`. If it's already open,
  `alreadyOpen` comes back true — calling it repeatedly is safe.
- **`close_page` is a commit, not a discard.** Closing commits that page's content to the
  model without confirmation (the C++ editor even writes it to file). Using it as "close
  to discard" produces the opposite result. That said, unconfirmed widget input — like a
  cell still in edit mode — can still be lost.
- **Once more than 20 tabs are open,** Creator automatically closes tab index 1 — and that
  closing commits, just like above. If you need to open many, close finished ones with
  `close_page` as you go.
- The only thing that can't be opened this way is a **standalone `.cpp`/`.h` file outside
  any POU** (a C++ POU itself does open) — open that directly in the Creator window.

## Values are read and written by path

Project settings (info, connection, redundancy, tasks) aren't each their own tool —
they're **one tree**, read and written with `get_object_data`/`update_object_data`. The
response has the same shape at every node — `data` is that node's value, `children` are
the names you can descend into (expand with `depth`).

```
/                            root = the project
├── info                     project properties (organization, author, memo, version)
├── connection               device address Creator connects to (address, secondaryAddress)
├── device/settings          operating settings (powerOnMode)
├── secondaryDevice/settings only when redundancy.enabled is true
├── redundancy               enabled — the redundancy switch
│   └── settings             link settings (interfaceName, two addresses, three timeouts, heartbeatMissCount, peerLossPolicy)
└── tasks/<name>             priority, comment
    ├── trigger              type (read-only), intervalMs
    └── programs             names (read-only)
```

- **Only `trigger.type` and `programs.names` are read-only** (registering/removing a
  program is the job of `add_prg_to_task`/`remove_prg_from_task`). Writing to them gives
  `data.read_only`.
- **A single call is one unit.** Even if it spans multiple nodes, if any one fails
  validation, nothing at all gets written. Failure doesn't stop at the first item — it's
  collected per-path.
- **The very first thing you'll probably try doesn't work** — turning the switch on and
  putting the settings underneath it in the same call. Validation runs against the state
  **before the call started**, so `/redundancy/settings` gets rejected with
  `data.unavailable`. **Split it into two calls** — succeed with `enabled: true` first,
  then write the settings.
- **Values written through this path have no undo.** Instead, a successful response
  carries `{path, before, after}` for every key that changed — to revert, collect those
  `before` values and send them back. This is the **only** way to undo it. `unchanged` is
  the list of keys that didn't change because they already held that value — don't confuse
  it with "rejected".
- **`availability: "unavailable"` means it can't be changed, not that it's hidden.** The
  value still comes back, but that key's **scalar value turns into a `{value,
  availability, reason}` object** — if you expected a string, this is where you get an
  object instead. Don't mistake this for the value disappearing.

Tasks split **structure from values** — create/delete/rename and program register/remove
have their own tools (`add_task`, `delete_task`, `rename_task`, `add_prg_to_task`,
`remove_prg_from_task`); priority, comment, and period go through the contract above.

**Redundancy addresses are two pairs with different meanings.** This is the single most
confusing point in this contract.

| Location | What it is |
|---|---|
| `/connection` (`address`, `secondaryAddress`) | **Which device Creator connects to for download** |
| `/redundancy/settings` (`primaryLinkAddress`, `secondaryLinkAddress`) | The link address **the two devices use to find each other** — this can be **a different network** than the one above |

A common setup wires maintenance access through a management network and the redundancy
heartbeat through a dedicated port. Assuming they're the same value and reading or writing
only one leaves you downloading to the wrong device, or with a redundancy link that never
connects.

## Ladder is a graph — lines are nodes, elements are edges

It's not a tree. **Lines (`lines[]`) are nodes, and elements are the edges connecting
them** — every element has `from`/`to` (line ids). This is exactly the shape
`get_ld_networks` returns.

```json
{
  "lines": [{"id": 0, "role": "start"}, {"id": 1}, {"id": 2}, {"id": 3, "role": "end"}],
  "elements": [
    {"type": "contact", "value": "cA", "from": 0, "to": 1},
    {"type": "contact", "value": "cB", "from": 0, "to": 2},
    {"type": "contact", "value": "cC", "from": 1, "to": 3},
    {"type": "contact", "value": "cD", "from": 2, "to": 3},
    {"type": "contact", "value": "cE", "from": 1, "to": 2}
  ]
}
```

cE is a **bridge** crossing between the two branches. `set_ld_networks` accepts any
arbitrary line graph that doesn't decompose into series/parallel — there's no constraint
like "only series is allowed" or "branches must merge at the same point." (The example
above shows only the topology. It has no coil, so building it as-is triggers `WMD02005
"Uncompleted logic exists."`.)

- **Network numbers are 0-based** — the first is `network: 0`, same as build errors
  (`Network-0`).
- The line with `role: "start"` **must be exactly one** (the left power rail). `"end"` is
  different — it's a marker that read auto-attaches to "a line with no outgoing edge," so
  **there can be several**, and writes don't check the count. Lines in the middle have no
  `role`.
- **`localId` is only a label you attach at write time — it isn't preserved on read-back**
  (it gets renumbered by model traversal order). Find an element you read back by `value`
  (or `function`+`instance`).
- **An empty line is read-only** — sending back an empty line exactly as read gets it
  discarded anyway, with `ld.empty_line_discarded`.
- For a non-series-parallel topology, **the listing order shifts for the first two
  round-trips and settles from the third** — the values and the line graph itself are
  always preserved; only labels and order change.

## Editing ladder — reach for the narrowest tool first

| What you want to do | Tool |
|---|---|
| A single element | `update_ld_element` · `insert_ld_element` · `delete_ld_element` |
| A network (rung) as a whole | `insert_ld_network` · `update_ld_network` · `delete_ld_network` · `move_ld_network` |
| The entire contents of networks | `set_ld_networks` |

**There are five element kinds** — contact · coil · box · jump · return. Fields differ per
kind, and the tool's `inputSchema` expresses this as a `oneOf` split on `element.type`.
**There is no `loop` kind** — FOR·NEXT·BREAK are `function` values of a `box`.

- If you don't know a box's parameter names, **`read_manual(keyword: "TON")`** gives pin
  names, types, and direction. You can also insert a box specifying only the function
  first and look at `params` in the response. **`list_variables` will not do it** — that
  only knows a POU's variable table, so it returns `pou.not_found`.
- `params` accepts either an array or a name map, meaning the same thing either way.
  **`update_ld_element` merges** (only the names you give change);
  **`insert_ld_element`·`set_ld_networks` replace the whole thing**.
- **Boxes have no modifiers** (even the GUI can't toggle invert/edge-detect on them).
- **`sourcecode` (a C++ fragment embedded in ladder) can only be read and deleted** —
  writing to it is not open in this contract (`ld.element_not_supported`). A network that
  contains one doesn't round-trip.

### Loops are boxes too

`function` accepts `FOR`·`NEXT`·`BREAK`. Case is ignored and read normalizes to uppercase.
`FOR` has four pins — `ST`·`ED`·`INC` (inputs), `IDX` (output); `NEXT`·`BREAK` take no
parameters (giving one produces `ld.param_not_found`). The selector has the same shape as
for a function box — `{type: "box", function: "FOR", occurrence: 2}`.

Changing `function` to a different name **auto-converts across all four directions** (box
to loop, loop to loop). Since the whole pin set changes, parameters are not merged —
**only what you give** is written. `ld.type_change_not_supported` now only appears when
**the element's kind itself** changes (e.g. `contact` to `coil`).

**Placement is constrained, and only `build_project` enforces it** — a bad layout is
accepted here and fails at build time. `FOR`/`NEXT` must each be the *only* element in their
network (`EMD02090`/`EMD02091`); `BREAK` must be *last* in its network (`EMD02129`);
`RETURN` is rejected inside a PRG — FC/FB only (`EMD02130`). **A PRG's early-exit substitute
is `jump` to a network `label`**, placed where `RETURN` would have gone.

A `jump` checks its `label` against labels **written earlier in the same call**, not just
the live model — writing a label and jumping to it in one `set_ld_networks` call works. A
missing label isn't blocked either; it warns `ld.jump_label_not_found`, and a **disabled**
network's label never counts as a destination.

### Rail pins on system function block boxes

A system FB box (`SR`, `TON`, `R_TRIG`, `CTU`, …) wires its **first input and first output
pin to the power rails**, named by the POU itself — the GUI doesn't even draw a pin there.
`get_ld_networks`/`insert_ld_element` still list it, marked `"rail": true` (the pin count
and order don't shift). A non-empty value is rejected with `ld.param_is_rail` (empty is
accepted, so reading a box back and writing it unchanged still round-trips).

Right shape: `contact → SR box (give only R) → coil` — the contact feeds the left rail
(`S1`), the coil receives the right rail (`Q1`); neither is a parameter you set. **FC boxes
are unaffected** — `OR`, `MOVE`, `EQ` keep every pin live.

### Box extension pins

14 functions — including
`ADD`·`MUL`·`SUB`·`DIV`·`AND`·`OR`·`XOR`·`MAX`·`MIN`·`MUX`·`AVG`·`CONCAT`·`COMB_BIT` —
grow new pins beyond their defined set if you give `IN3`·`IN4`… and so on. The prefix is
`IN`, except `S` for `CONCAT` and `BIT` for `COMB_BIT`.

- **They can only be created at insertion time.** Trying to add a new extension pin to an
  already-placed box via `update_ld_element` gives `ld.param_not_found` (which points you
  to rewriting that network with `set_ld_networks`). **Changing the value** of a pin that
  already exists is fine.
- **They can't be deleted.** Even the Creator window can't do this, so all you can do is
  clear the value.
- **Numbers fill in contiguously** — if `IN2` already exists and you request `IN5`, `IN3`
  and `IN4` get created too, with empty values. There's no way to create just one specific
  number.
- **The cap is 16 total, same as the GUI** (only `COMB_BIT` is 8; exceeding it gives
  `ld.param_limit_exceeded`). The pin number usually equals the total count, but
  **`CONCAT`'s defined parameters `IN1`·`IN2` use a different prefix than `S`, so they're
  counted separately** — it passes up through `S14` and gets rejected starting at `S15`.

### Placement and network properties

There are two ways to decide where a new element goes. `insert_ld_element` accepts both;
`set_ld_networks` gives `from`·`to` directly for every element.

| Form | Shape | What it does |
|---|---|---|
| **Series** | `anchor: {after: {localId: 1}}` | **Splits the line** the element attaches to and inserts between the halves |
| **Parallel/bridge** | `element: {..., from: 0, to: 1}` | **Hangs an edge** between two existing lines (no anchor) |

There's no dedicated tool to **close** a branch — `element.to` on `update_ld_element` does
that job, and it only works when the element exclusively owns the destination line, has
nothing downstream, and creates no cycle (otherwise it's rejected with
`ld.close_branch_ambiguous`·`ld.close_branch_orphans`·`ld.topology_cycle`, leaving the
model completely untouched). Deleting a branch is `delete_ld_element`. **There is no tool
to create or delete a line directly** — lines are handled only through an element's
`from`·`to`.

A network holds **label, comment, and disabled** separately from its elements.
`update_ld_network` changes only what you give; `insert_ld_network` fills them in on
creation; `set_ld_networks` preserves the current value when you omit them.

- **A network with `disabled: true` is excluded entirely from the build** — the build
  passes even if its content wouldn't compile. An error inside it comes back tagged
  `disabledNetwork: true` under **`warnings`, not `errors`** — re-enable the network and
  it's a build error again; active-network errors still fail the build.
- `label` is a `jump` destination. **A duplicate isn't blocked** — it comes back with an
  `ld.duplicate_network_label` warning naming the conflicting network number, and leaving
  it as-is gets caught at build time by `EMD02101`.
- **These three fields on `update_ld_network` don't pass through the undo stack** (neither
  does the Creator UI) — a person's Ctrl+Z won't bring them back, and `revision` doesn't
  bump either. A change made via `set_ld_networks` counts the whole call as a single undo.

## Variables

`list_variables` narrows with `nameContains`. Add and edit with
`add_variable`·`update_variable`. Renaming pops a dialog asking whether to update
references too.

**A malformed address or initial value isn't rejected — it's reported through `warnings`**
— same as typing directly into the Creator window, which accepts an odd value rather than
blocking it. Always read the response's `warnings`.

## User-defined types (DUT)

`list_duts` gives only name, kind, `system`, and `memberCount` — it **never carries
`members`** (there's no cap on member count, so including it all would blow up the
response). Check `memberCount` and fetch only what you need with `get_dut`. **There is no
tool that returns everything at once.**

- There are **only three kinds — struct, enum, typedef.** Union and FB types are outside
  this contract and are rejected with `dut.out_of_contract`, whose message tells you where
  to look instead (FB is `list_pous`).
- **There is one shared namespace** — if struct `Foo` exists, you can't create enum `Foo`
  (`dut.name_taken`).
- **System DUTs are read-only** and don't show up in the list by default — pass
  `includeSystem: true` to surface them.
- **The count cap is 128 per kind, 512 total.** A struct or enum **can never have zero
  members** — an empty `members[]` won't create one, and you can't delete the last
  remaining member either.
- An enum's underlying type is **fixed at INT** (there's no argument to change it).
- `array` has **different notation for input and output** — you write `"[0..9]"`, but
  `get_dut` returns `"ARRAY [0..9] OF DINT"`. The parser reads only the bracketed range,
  so **sending back either form works.**

**The project tree doesn't follow along.** `add_dut`·`delete_dut`·`rename_dut` don't
refresh the tree view — the value changes correctly and
`list_duts`·`list_pages`·`open_page` reflect it right away, but for a person to find it on
screen they must **close and reopen the project.** If the user says they can't find a DUT
they just created, lead with this. A tab still open on a deleted DUT also stays stale.

**Deletion is rejected if in use.** `delete_dut` returns `dut.in_use` along with **where
it's used** in `errorDetail.references` — this counts not just global/POU variables but
other DUTs' members and a TypeDef's reference type too. **There is no `force` argument.**

**Bulk and single-item operations produce the same result.** The four single-item tools
(`add_dut_member`·`update_dut_member`·`delete_dut_member`·`move_dut_member`) pass through
the same validator as `set_dut_members`, so nothing is left half-changed. Rename a member
with **`newName`**, separate from `member` (its current name).

**`before` is the only way to undo** (there's no undo here either). Which tool you send it
back to depends on which tool you used.

- `update_dut`·`rename_dut` — send it straight back to **the same tool**.
- The five member tools — `before` is a **member array**, so put it into
  `set_dut_members`'s `members`.
- `delete_dut` — `before` also carries `system` and `memberCount`, and `add_dut` rejects
  those as unrecognized fields. **Pick out only the fields `add_dut` accepts** — for
  struct·enum: `{kind, name, comment, members}`; for typedef: `{kind, name, comment,
  referenceType, array, minimum, maximum}`.

## The namespace field exists but isn't active

The five tools `add_dut`·`update_dut`·`add_pou`·`add_variable`·`update_variable` all have
`namespace` in their schema, but **giving it a value gets rejected with
`namespace.unsupported`.** Omitting it or passing an empty string passes through — the
field is reserved for a place that isn't open yet. Right now, user-created elements land
in the global scope and only built-in elements live inside `Mulin`, so an unqualified name
is never ambiguous.

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

`list_creator_instances` gives the same candidate list on demand — call it any time to see
every detected window, including one **stuck behind a dialog** (a crash-recovery prompt,
for instance). That window has no project open yet, so its `projectPath` comes back empty,
but it still shows up here. Pin to it with `use_creator_instance`, then use
`list_dialogs`/`click_dialog_button` to close the dialog — this is the way out of a session
that would otherwise be stuck between two windows with no way to choose.

This is a different situation from the "multiple candidates" rejection
`/mulin-creator:check-mcp` describes below — that one happens *before* this bridge has ever
attached to anything, and its fix is still `MULIN_MCP_PORT` plus a fresh session.
`creator.instance_changed` only happens *after* a successful attach, mid-session, and its
fix (`use_creator_instance`) needs no restart at all.

## When you can't connect

Run `/mulin-creator:check-mcp`. It pinpoints whether Creator is closed, whether there are two
windows and it couldn't tell which one, or whether a stale lock file was left behind.
