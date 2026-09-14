# POUs

**A POU is a container; LD, C++, and ST are languages used inside one.** Most mistakes
here come from treating "a ladder POU" and "a C++ POU" as two different kinds of object.
They are not — they are the same kind of object, and only what lives inside differs.

- There are **three POU kinds — `prg`, `fc`, `fb`** — and that is what the path segment
  after `/pou/` names. Get the names from `list_pous`; don't invent them.
- **The page path `/pou/prg|fc|fb/<name>` doesn't distinguish LD from C++ POUs.** They open
  exactly the same way, so the path is not what tells you the language. Each `list_pous`
  entry carries a `language` field — `"ld"` or `"cxx"` — and the listing can be filtered by
  it, so **don't open a POU just to find out what it is.**
- **`list_pous` names are not page paths.** With `builtin: true` the listing also carries
  system FC/FBs, and those have no page at all — assembling `/pou/fc/ADD` and opening it
  gets `page.not_found`. **Page paths come from `list_pages`, and only from there.**
- **Some tools only work while the POU's editor is open** — that is why `open_page` comes
  before touching ladder or adding variables, not after a call fails.

## Structure tools answer their own dialogs

`add_pou`·`delete_pou`·`rename_pou` change the structure; what is *inside* a POU is changed
by the language's own tools (`*_ld_*` for ladder) or by the editor. The two destructive
ones don't behave the way a GUI user would expect.

- **`delete_pou` presses Yes on the confirmation dialog itself.** The user never sees
  "really delete?", so **you** are the only checkpoint. Ask before calling it unless the
  user asked for that deletion on the spot.
- **Deleting a C++ POU deletes its `Cxx/<name>/` folder too** — source the user wrote by
  hand, gone, with **nothing in this tool set that can undo it.**
- Deletion is refused with `pou.delete_unsafe` when the project tree's selection doesn't
  match the target. That is a safety check firing, not a bug to work around: the underlying
  UI path deletes *everything selected*, so the tool refuses rather than risk taking more
  than you named. Built-in FC/FBs are refused separately with `pou.builtin_readonly`.
- **`rename_pou` closes its own warning dialog** and returns the text as
  `pou.rename_failed`. So a rename failure arrives as an ordinary error response — there is
  no dialog left open for you to find, and nothing for the user to click.

## The variable table belongs to a POU

**With `scope: "pou"`, `list_variables` looks up a POU by name, and only a POU.** Ask it for the parameter
names of a ladder box and it answers `pou.not_found` — the box's function name isn't a POU.
Read that error carefully rather than as "the POU is missing": **its message lists the POUs
that do exist**, which usually settles what went wrong in one look.
