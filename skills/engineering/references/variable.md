# Variables

## Declaring them

`list_variables` takes a **required `scope`** — `pou`, `global`, or `system` (read-only).
Omitting it is `params.missing`, and `pou` needs the POU name as well. `nameContains`
narrows by name. To find a variable without knowing its scope, use `search_project`.

Add, change and remove with `add_variable`·`update_variable`·`delete_variable`. **With
`scope: "pou"` those three need that POU's editor open** — `open_page` on
`/pou/<kind>/<name>` first. `list_variables` does not; it reads the model directly.

### A bad address or initial value is dropped, not stored

If the address or the initial value doesn't parse, **it is not applied at all.** The field
keeps what it had (usually nothing), the call still succeeds, and the only sign is a
warning: `variable.address_not_applied` or `variable.initial_value_not_applied`.

**Compare what came back with what you sent** — the response carries the variable as it
actually now is. **The build will not catch this for you**: a variable left without an
address simply gets one assigned, so the project compiles and the fault surfaces after a
download, as I/O that doesn't move.

### `update_variable` renames without asking

`newName` also rewrites every ladder parameter that used the old name. The Creator UI asks
"change all N references?" — **this tool clicks Yes for you**, because answering No would
leave ladder pointing at a name that no longer exists and break the build.

- **Don't tell the user they will be asked to confirm.** By the time the call returns, the
  references are already rewritten.
- Don't go looking for the dialog either — nothing will be pending, and this is not a
  source of `creator.busy`.
- The response doesn't say how many references changed. If that number matters, count them
  with `search_project` **before** you rename.

### `delete_variable` always warns

Every successful delete carries `variable.deleted_may_be_in_use` — the tool doesn't check
ladder usage before deleting, so the warning is unconditional. It isn't evidence that
something is wrong, and it isn't noise either: if the variable *was* in use,
`build_project` is where that shows up. Build after deleting.

## Live values

- `read_variable_values` — the value **at the moment you call**. Use it to sample a number
  once.
- `write_variable_values` — **changes what a running machine does**, so it belongs to the
  same "ask first" class as the device calls. A variable the program overwrites every scan
  loses your value on the next scan.
- `watch_variables` · `read_watched_values` · `unwatch_variables` — **one mechanism, not
  three tools.** `watch_variables` puts paths on a list that keeps sampling on its own
  period; `read_watched_values` is the only way the collected value and its history come
  back; `unwatch_variables` takes paths off and **discards their history**, so re-watching
  a path starts from empty.

**None of this needs the person's monitoring toggle to be on.** `watch_variables`,
`read_variable_values` and `write_variable_values` do need a project open and the device
connected (`project.not_open`, `device.not_connected`). **`read_watched_values` and
`unwatch_variables` deliberately have no such gate** — that is the point of the watch list.
After the device drops, `read_watched_values` still hands back everything collected up to
the moment it went away, so don't refuse to look just because the link is down.

Four things to hold on to:

- **History is a ring buffer — 64 changes per item.** Beyond that the oldest are discarded,
  and how many were dropped comes back per item as `droppedChanges`. **Read that field
  before calling a period quiet.** A non-zero value means the early part of the window is
  gone, not that nothing happened in it.
- **Sampling is periodic polling, so a pulse shorter than the period is invisible** — in
  the value and in the history alike. If the question is "did this ever go true for one
  scan", say the mechanism cannot answer it rather than answering "no".
- **`hasSample: false` is not a value of zero.** It means the watch is registered but no
  report has arrived yet. Asking for a path you never watched doesn't fail the call either;
  that path comes back marked as not watched while the rest answer normally.
- **Per-item rejection becomes whole-call failure when nothing survives.** Unwritable items
  are skipped individually, but if no item is left to write, the call fails with
  `value.nothing_writable`. And `value.unsupported_type` is a wider net than its name — it
  also covers a fraction sent to an integer type, a value outside that type's range, and
  integers beyond 2^53. `1.5` to an INT is refused while `2` writes fine, so **don't
  conclude the type can't be written.**
