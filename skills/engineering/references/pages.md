# Pages

`path` follows the project browser's structure, but **each segment is a fixed key that
isn't localized.** The name shown on screen comes back separately as `title` — **use
`title` when talking to the user, `path` when calling a tool.** Get both from `list_pages`,
whose entries are `{path, title, open}` — **`open` already tells you whether the page is up**,
so check it instead of calling `open_page` to find out.

When pruning with `under`, it cuts **only at segment boundaries** (`under: "/pou"` does not
match `/pouX`). Its spelling is strict: no leading slash, a trailing slash, or an empty
segment is `page.path_invalid` rather than an empty result — `"/pou"` is right, `"pou"` and
`"/pou/"` are not.

| Path | |
|---|---|
| `/projectProperty` · `/globalVariable` · `/systemVariable` · `/addressComment` | Single page |
| `/dut/struct\|enum\|typedef/<name>` | System data types live in the same place |
| `/pou/prg\|fc\|fb/<name>` | One page per POU, whatever language it holds |
| `/task/configuration` · `/task/monitoring` | |
| `/controller/operation` · `/controller/configuration` | configuration exists only on certain CPU models |
| `/externalDevice/<name>` | |
| `/redundancy` · `/redundancy/operation` · `/redundancy/configuration` | the first two exist only when redundancy is on; the third also needs the CPU model |

- **A missing `configuration` page is not a fault to report.** Both `/controller/configuration`
  and `/redundancy/configuration` are gated on the CPU being one of a specific few models —
  a TOP-series CPU can still be outside that set. If the page isn't listed, this CPU simply
  isn't one of them. Likewise, seeing `/redundancy` and `/redundancy/operation` **without**
  `/redundancy/configuration` doesn't mean redundancy is off; that third page carries the
  extra model gate the other two don't.
- **`title` is not unique.** `/controller/operation` and `/redundancy/operation` share one
  title, and so do the two `configuration` pages. In a redundant project, "I opened
  Operation Setting" tells the user nothing — **say which one, with the path**, whenever
  the title alone is ambiguous.
- `open_page` opens **in a background tab by default** (it doesn't steal the tab the
  person was looking at). To bring it forward, pass `focus: true`. If it's already open,
  `alreadyOpen` comes back true — calling it repeatedly is safe.
- **Being in the list is the intent, not a guarantee.** A listed path that won't open comes
  back as `page.not_found` — the same code as a path that doesn't exist — but **the message
  says so in words**: it tells you the path was listed and still didn't open. Read the
  message before you conclude you mistyped. **Don't retry with spelling variations**;
  report it as what it is.
- **Closing a loaded page commits it.** Its content goes into the model without
  confirmation, and the C++ editor writes it to file. (A tab restored with the project and
  never touched isn't loaded yet, so closing that one commits nothing — but don't build on
  it: if anything opened or edited the page, it is loaded.) What you *can* still lose is
  unconfirmed widget input — a cell left in edit mode, for instance.
- **Once more than 20 tabs are open,** Creator automatically closes tab index 1 — and that
  closing commits, just like above, on a page you never chose to close. If you need to open
  many, close finished ones with `close_page` as you go.
- The only thing that can't be opened this way is a **standalone `.cpp`/`.h` file outside
  any POU** (a C++ POU itself does open) — open that directly in the Creator window.
