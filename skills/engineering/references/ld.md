# Ladder (LD)

## Ladder is a graph — lines are nodes, elements are edges

It's not a tree. **Lines (`lines[]`) are nodes, and elements are the edges connecting
them** — every element has `from`/`to` (line ids). This is exactly the shape
`get_ld_networks` returns.

```json
{
  "lines": [{"id": 0, "role": "start"}, {"id": 1}, {"id": 2}, {"id": 3, "role": "end"}],
  "elements": [
    {"localId": 1, "type": "contact", "value": "cA", "from": 0, "to": 1},
    {"localId": 2, "type": "contact", "value": "cB", "from": 0, "to": 2},
    {"localId": 3, "type": "contact", "value": "cC", "from": 1, "to": 3},
    {"localId": 4, "type": "contact", "value": "cD", "from": 2, "to": 3},
    {"localId": 5, "type": "contact", "value": "cE", "from": 1, "to": 2}
  ]
}
```

**Trimmed to the topology** — a real read also carries `negated` and `edge` on every
contact. `localId` is not trimmed: read always sends it, and `set_ld_networks` **requires
it on every element** (omit it and they all default to 0 and collide, `params.invalid`).

cE is a **bridge** crossing between the two branches. `set_ld_networks` accepts any
arbitrary line graph that doesn't decompose into series/parallel — there's no constraint
like "only series is allowed" or "branches must merge at the same point." The example has
no coil, so building it as-is triggers `WMD02005 "Uncompleted logic exists.."` — two
periods, if you match that string against build output.

- **Network numbers are 0-based** — the first is `network: 0`, same as build errors
  (`Network-0`).
- The line with `role: "start"` **must be exactly one** (the left power rail). `"end"` is
  different — it's a marker that read auto-attaches to "a line with no outgoing edge," so
  **there can be several**, and writes don't check the count. Lines in the middle have no
  `role`.
- **The `localId` you read back is the coordinate to edit by.** Read assigns it from a
  traversal that is the same every time, so it still points at the same element on your
  next call, and a selector resolves it before any other field. `insert_ld_element` hands
  back `inserted.localId` for exactly this — anchor the next edit on it.
- **A `localId` you invented is not preserved.** `set_ld_networks` renumbers everything you
  send by traversal order. Read first, then use what came back.
- **A selector takes only these seven fields** — `localId`, `type`, `variable`, `function`,
  `instance`, `label`, `occurrence`. Anything else is `params.invalid`. **A contact or coil
  operand is `variable` here, not `value`** — even though read hands that same operand back
  as `value`. Sending it back under that name is refused on the spot, not misapplied.
- **An empty line is read-only** — sending back an empty line exactly as read gets it
  discarded anyway, with `ld.empty_line_discarded`.
- **In a non-series-parallel topology, don't trust the listing order** — the values and the
  line graph itself are always preserved; only labels and order change.

## Editing ladder — reach for the narrowest tool first

| What you want to do | Tool |
|---|---|
| A single element | `update_ld_element` · `insert_ld_element` · `delete_ld_element` |
| A network (rung) as a whole | `insert_ld_network` · `update_ld_network` · `delete_ld_network` · `move_ld_network` |
| The entire contents of networks | `set_ld_networks` |

**Ladder writes go through the undo stack** — one call is one undo step, so a person's
Ctrl+Z reverts it, and that is the way back from a bad write (the three network property
fields at the end of this file are the one exception). **Ladder responses carry no
`before`**; looking for one here wastes the recovery you already have. (The `before` inside
`anchor: {before: …}` is a placement argument, not a prior value.)

**There are five element kinds** — contact · coil · box · jump · return. Fields differ per
kind, and the tool's `inputSchema` expresses this as a split on `element.type`: a `oneOf`
for insert and set, but an **`anyOf` for update** — update omits `type` from the schema's
`required` array, which would make an exclusive `oneOf` unmatchable. **Send `type` anyway:
the server still demands it**, as a check that the element is the kind you think
(a mismatch is `ld.type_change_not_supported`).
**There is no `loop` kind** — FOR·NEXT·BREAK are `function` values of a `box`.

- If you don't know a box's parameter names, **`read_manual(keyword: "TON")`** gives pin
  names, types, and direction. You can also insert a box specifying only the function
  first and look at `params` in the response. **Don't try `list_variables`** — it only
  knows the project's own POUs, so a standard function name comes back `pou.not_found`.
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
to box, box to loop, loop to box, loop to loop). Since the whole pin set changes, parameters are not merged —
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

### Rail pins on function block boxes

**Any function block box** wires its **first input pin to the left power rail** — the
built-in ones (`SR`, `TON`, `R_TRIG`, `CTU`, …) and your own FBs and FB-kind DUTs alike.
The POU names that pin itself; if it names none, the rail pin is `EN`. The GUI doesn't even
draw a pin there. `get_ld_networks`/`insert_ld_element` still list it, marked
`"rail": true` (the pin count and order don't shift), and a non-empty value is rejected
with `ld.param_is_rail`.

- **The output rail may not exist.** Its name can come back empty, which means that box has
  no power-output pin at all — don't assume the first input and first output always pair
  up.
- **Strip `rail` before you write the box back.** Read puts it on the parameter entry, but
  the write schema allows only `name`, `value` and `access` and forbids anything else. The
  server itself ignores the extra key, but a client that validates the schema will refuse
  the call before it ever gets there — so "read it and send it back unchanged" is exactly
  the move that breaks.

Right shape: `contact → SR box (give only R) → coil` — the contact feeds the left rail
(`S1`), the coil receives the right rail (`Q1`); neither is a parameter you set. **FC boxes
are unaffected** — `OR`, `MOVE`, `EQ` keep every pin live.

### Box extension pins

Thirteen functions —
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
| **Series** | `anchor: {after: {localId: 1}}` or `anchor: {before: {localId: 1}}` | **Splits the line** the element attaches to and inserts between the halves |
| **Parallel/bridge** | `element: {..., from: 0, to: 1}` | **Hangs an edge** between two existing lines (no anchor) |

**In a network that already has elements, one of the two is required** — leave out both
`anchor` and `from`/`to` and the call fails with `params.invalid`. Only an empty network
lets you omit them.

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
  passes even if its content wouldn't compile. When a **ladder write tool** diagnoses a
  problem inside such a network it demotes it to **`warnings`, not `errors`**, tagged
  `disabledNetwork: true`. Re-enable the network and the same thing is a build error again;
  errors in active networks still fail the build.
- `label` is a `jump` destination, and **a duplicate is never blocked.** Whether you are
  even told depends on the tool: `insert_ld_network` and `update_ld_network` warn with
  `ld.duplicate_network_label`, naming the conflicting network. **`set_ld_networks` does
  not check at all** — write several networks at once and a label collision comes back as a
  clean success, surfacing much later as `EMD02101` at build time. After a bulk write,
  check your own labels; nothing else will.
- **These three fields on `update_ld_network` don't pass through the undo stack** (neither
  does the Creator UI) — a person's Ctrl+Z won't bring them back, and `revision` doesn't
  bump either. A change made via `set_ld_networks` counts the whole call as a single undo.
