# User-defined types (DUT)

`list_duts` gives name, kind, `system`, `memberCount`, and `comment` when there is one — it
**never carries `members`**. Check `memberCount` and fetch only what you need with
`get_dut`. **There is no tool that returns everything at once.**

- There are **only three kinds — struct, enum, typedef.** Union and FB types are rejected,
  but by different codes depending on where you meet them: **looking one up** gives
  `dut.out_of_contract`, while `add_dut(kind: "union")` is just `params.invalid` — `kind`
  only ever parses as those three. Only the FB message names somewhere else to look
  (`list_pous`); the union and base-type messages don't.
- **The name has to be free across the whole project, not just among DUTs.** `dut.name_taken`
  comes back if the name is already a global variable, a local variable in *any* PRG, a POU,
  or another DUT. So the natural choice — naming a struct after the thing it describes,
  `Motor` or `AxisData` — is exactly what tends to collide. **Don't go hunting for a DUT of
  that name when this fires**; it is usually a variable or a POU.
- **System DUTs are read-only** and don't show up in the list by default — pass
  `includeSystem: true` to surface them.
- **The count cap is 128 per kind, 512 total — and the total is checked first.** The 512 is
  a shared budget that also counts base types, FB mirrors and system structs, so it can run
  out while the kind you're adding still has room. `dut.limit_exceeded` naming the total is
  not a contradiction of "only 40 structs exist". A struct or enum **can never have zero
  members** — an empty `members[]` won't create one, and you can't delete the last
  remaining member either.
- An enum's underlying type is **fixed at INT** (there's no argument to change it).
- `array` has **different notation for input and output** — you write `"[0..9]"`, but
  `get_dut` returns `"ARRAY [0..9] OF DINT"`. The parser reads only the bracketed range,
  so **sending back either form works.** It is not unlimited, though: **each bound is at
  most five digits and there are at most three dimensions**, so `"[0..200000]"` is
  `dut.invalid` — and the message spells those limits out, so read it instead of guessing.
- **Leaving `name` out of `add_dut` doesn't fail** — it creates the type under a generated
  name (`Struct1`, `Struct2`, … — no underscore), exactly as the tree's "new" command does.
  If you meant to name it, look under that generated name rather than creating a second one.

**The project tree doesn't follow along.** `add_dut`·`delete_dut`·`rename_dut` don't
refresh the tree view — the value changes correctly and
`list_duts`·`list_pages`·`open_page` reflect it right away, but for a person to find it on
screen they must **close and reopen the project.** If the user says they can't find a DUT
they just created, lead with this. (Open **tabs** are handled for you: the write tools
reload the tab, and only `delete_dut` closes it.)

**Deletion is rejected if in use.** `delete_dut` returns `dut.in_use` along with **where
it's used** in `error.detail.references` — this counts not just global/POU variables but
other DUTs' members and a TypeDef's reference type too. **Read the array, not the
sentence**: the human-readable message stops after 20 entries, while the structured list
doesn't. **There is no `force` argument.** A successful delete also **removes every
bookmark under that DUT**, and no `before` payload brings those back.

**Bulk and single-item operations produce the same result.** The four single-item tools
(`add_dut_member`·`update_dut_member`·`delete_dut_member`·`move_dut_member`) pass through
the same validator as `set_dut_members`. Rename a member with **`newName`**, separate from
`member` (its current name).

## Undoing: `before` is raw material, not a request body

There is no undo here, and `before` is what you have — but **only the member tools give you
something you can send straight back.** For the type-level tools you have to build the
call yourself, and sending `before` as-is fails immediately.

- **The five member tools** — `before` is a **member array**, so put it into
  `set_dut_members`'s `members`. These rebuild the member list wholesale, so this really
  does restore the previous state.
- **`rename_dut`** — `before` is `{name: <the old name>}`, and the tool needs both `name`
  and `newName`. **`before.name` is the destination, not the subject.** Send
  `{name: <the current name>, newName: before.name}`. Passing `before` unchanged is
  missing `newName`, and reading it as the subject renames the wrong direction.
- **`update_dut`** — `before` carries only the fields that can change; **it has no `name`**,
  which the tool requires. Add it yourself: `{name: <the type's name>, ...before}`.
- **`update_dut` on a typedef that had no `array`** — `before` carries `array` only if
  there already was one, and the tool ignores the key when it is absent, so replaying
  `before` leaves the array you just added in place. An empty string won't remove it either
  (`dut.invalid`). **Adding an array to a typedef is, in practice, not revertible through
  this path** — decide before you do it, not after.
- **`delete_dut`** — `before` also carries `system` and `memberCount`, and `add_dut` rejects
  those as unrecognized fields. **Pick out only the fields `add_dut` accepts** — for
  struct·enum: `{kind, name, comment, members}`; for typedef: `{kind, name, comment,
  referenceType, array, minimum, maximum}`. Bookmarks are gone regardless.
