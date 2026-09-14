# Build, device, monitoring, simulation

The core file already covers how long these calls take and which of them are
irreversible. This file is the part that is easy to walk past: **you never name the device
in the call.**

## Establish which device before you act on it

`download_to_device`, `start_plc`, `stop_plc` and `reset_plc` act on whatever the open
project is configured to connect to. Nothing in the call names it, so no call ever *looks*
aimed at the wrong one.

- **The identity of the device is a project setting**, not something a status call reports.
  Read `/connection` with `get_object_data` — `address` and `secondaryAddress` are the
  answer, and `references/settings.md` explains why a redundant project has two of them
  that are easy to mix up. Say which one you are about to act on before you act.
- **`get_device_status` answers a different question** — whether the link is up and what
  the device is doing (`state`, `operatingState`). Useful, and necessary, but it will not
  tell you *which* device you are looking at.
- **What actually changes the target is `update_object_data` on `/connection`.**
  `connect_device` and `disconnect_device` only open and close the link to whatever that
  setting already names — reaching for them to "switch devices" does nothing of the kind.

## You don't need to build first

`download_to_device` runs the build itself. A build failure ends the call with
`build.failed` and **nothing is written to the device**, so there is no race to lose here.
Calling `build_project` first to be safe just spends the same minutes twice. Build on its
own when you want the errors and warnings without touching equipment.

## Monitoring

If a ladder tool rejects an edit and nothing about the ladder looks wrong, **check the
monitoring state before anything else** — that rejection has no other common cause, and it
is the one that reads like a bug in your own payload.

## Simulation

`start_simulation` is not a peer of the calls above — **it does the whole sequence
itself**: launches the simulator, connects, builds, downloads, and turns monitoring on.
Don't call `connect_device`, `build_project` or `download_to_device` around it. Like a
download it doesn't respond until the build finishes. If the project is in online mode it
refuses with `simulation.online_mode`, so disconnect the device first. `stop_simulation`
ends it.

**Returning is not the same as running.** The call answers when monitoring comes up, which
is earlier than execution: with `RunAfterDownload` on (the default) the program starts
about 1.5 seconds after the transfer, and with it off it doesn't start at all. Poll
`get_device_status` until `operatingState` is `run`, or call `start_plc`. Read values
before that and you get initial values everywhere — which is how a session talks itself
into "fixing" ladder that was never broken.
