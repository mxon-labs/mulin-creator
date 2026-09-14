# Project settings

Project settings (info, connection, redundancy) aren't each their own tool —
they're **one tree**, read and written with `get_object_data`/`update_object_data`. The
response has the same shape at every node — `data` is that node's value, `children` are
the nodes below it.

```
/                            root = the project
├── info                     project properties (organization, author, memo, version)
├── connection               device address Creator connects to (address, secondaryAddress)
├── device/settings          operating settings (powerOnMode)
├── secondaryDevice/settings backup device settings (always present; writable only with redundancy on)
├── redundancy               enabled — the redundancy switch
│   └── settings             link settings (interfaceName, two addresses, connectionTimeoutMs, communicationTimeoutMs, heartbeatTimeoutMs, heartbeatMissCount, peerLossPolicy)
└── tasks/<name>             a branch of its own
```

Every path starts at the project root `/` — a path without the leading slash is rejected,
and so is an empty segment (`//`). Both come back as **`data.path_not_found`**, which reads
like "no such setting" when the real problem is the spelling of the path.

## `depth` limits, it doesn't expand

**Leave `depth` out and you get the entire subtree, fully expanded** — that is the default,
not a summary. `children` then holds whole node objects, not names.

**`depth: 0` is what gives you a list of child names.** Reach for it when you're orienting
yourself; reach for the default only when you actually want everything. Calling
`get_object_data("/")` with no arguments to "see what's there" returns the whole tree, and
then reading `children[0]` as a string gets you an object instead.

## `availability: "unavailable"` sits at two different levels

Unavailable means **can't be changed**, not hidden — the value still comes back either way.
But *where* the marker appears differs, and only one of the two is visible in the value.

- **Node level** — `availability` and `reason` appear at the **top of the node object**,
  and the keys inside its `data` look like ordinary scalars. There are three such nodes:
  `/connection`, `/secondaryDevice` (its `settings` child inherits) and
  `/redundancy/settings`. **A plain-looking scalar here does not mean it is writable** —
  check the node, not the value. Nodes inherit: a child with no rule of its own is
  unavailable when an ancestor is. **`/device/settings` has no rule anywhere above it**, so
  a `powerOnMode` write that fails failed for some other reason — don't go looking for
  availability.
- **Key level** — the key's **scalar turns into a `{value, availability, reason}` object**.
  In practice `/connection/secondaryAddress` is the only key that does this, so this is a
  shape to recognise, not a pattern to generalise.
- **`schema: true` suppresses the key-level wrapper entirely** — it only exists on the
  plain-value path. Don't use a schema read to find out what's writable.

## What actually blocks a write here

- **`/connection` is locked outright while the device is connected.** The whole node, both
  addresses — the message tells you to `disconnect_device` and retry. Since you usually
  come here as part of getting ready to download, this is the single most likely rejection
  in this file, and it is *not* the redundancy trap below.
- **The very first thing you'll probably try doesn't work** — turning the redundancy switch
  on and putting the settings underneath it in the same call. Validation runs against the
  state **before the call started**, so `/redundancy/settings` gets rejected with
  `data.unavailable`. **Split it into two calls** — succeed with `enabled: true` first,
  then write the settings.
- **`secondaryAddress` is unavailable until redundancy is enabled** — and because **a call
  is one unit, one rejected key discards the whole call.** Write `address` and
  `secondaryAddress` together on a project where redundancy is still off and you don't get
  a partial success: **the primary address is thrown away too**, and only the secondary is
  named in the error.

## Redundancy addresses are two pairs with different meanings

This is the single most confusing point in this contract.

| Location | What it is |
|---|---|
| `/connection` (`address`, `secondaryAddress`) | **Which device Creator connects to for download** |
| `/redundancy/settings` (`primaryLinkAddress`, `secondaryLinkAddress`) | The link address **the two devices use to find each other** — this can be **a different network** than the one above |

A common setup wires maintenance access through a management network and the redundancy
heartbeat through a dedicated port. Assuming they're the same value and reading or writing
only one leaves you downloading to the wrong device, or with a redundancy link that never
connects.
