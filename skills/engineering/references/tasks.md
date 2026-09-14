# Tasks

A task's values live in the project settings tree, reached by path with
`get_object_data`/`update_object_data`.

```
/tasks/<name>                priority, comment
├── trigger                  type (read-only), intervalMs (interval tasks only)
└── programs                 names (read-only)
```

Every path starts at the project root `/` — a path without the leading slash is rejected.

- **`list_tasks` is not just a list of names.** Each entry already carries the number, kind,
  priority, comment, trigger (including `intervalMs`) and the registered programs. One call
  usually answers the whole question — don't follow it with a `get_object_data` per task.
- **Only `trigger.type` and `programs.names` are read-only** (registering/removing a
  program is the job of `add_prg_to_task`/`remove_prg_from_task`). Writing to them gives
  `data.read_only`.
- **Structure and values are split.** Create, delete and rename are `add_task`,
  `delete_task`, `rename_task`; registering and unregistering a program are
  `add_prg_to_task`, `remove_prg_from_task`. Priority, comment and period go through
  `get_object_data`/`update_object_data`. Looking for a tool that does both at once is how
  time gets lost here — there isn't one.

## `intervalMs` exists only on interval tasks

In the settings tree, `trigger.type` is one of three — `interval`, `bitEvent`,
`taskFinished` — and comes back as an **empty string** if the task somehow holds a value
outside them. (`list_tasks` is a different surface: there a task with no condition at all
reports `"none"`, which the tree has no option for.) **Only an `interval` task has an
`intervalMs` key**; on the others the key simply isn't in the tree, and writing it is
`data.path_not_found`.

That error reads like a typo, which makes it worse than it looks: **a call is one unit**, so
if you are setting periods across several tasks and one of them isn't an interval task,
**every other task's change is discarded too.** Read `trigger.type` before you write a
period — `list_tasks` already told you.

## A task can exist and still have no path

Three kinds of task names are **skipped when the `/tasks` tree is built**: an empty name, a
name containing `/`, and a duplicate of one already declared. The skip leaves a warning in
Creator's own log — **nothing in the MCP response says it happened.**

So a task can show up in `list_tasks` and have no reachable path at all, and the Creator UI
does not stop a person from typing `/` into a task name. `"Line/A"` is the nasty one:
`/tasks/Line/A` is a perfectly well-formed path that means "the `A` node under task
`Line`", so you get a confusing `data.path_not_found` about a task you can see.

**If a task is in `list_tasks` but its path isn't in the tree, look at the name first** —
and say so, rather than reporting the settings tree as broken.
