# cursed

A tiny always-on-top window showing which Cursor conversations are running, what they are
doing, and how long they have been at it.

```
┌────────────────────────────────────────────┐
│ cursed                          2 running  │
│ ● Mac app performance strategies   51m 30s │
│   screenlink · Edited db.ts, index.ts…     │
│ ● Cursor app status window         31m 12s │
│   cursed · Edited ContentView.swift…       │
│ ✓ Future of architect tools         4m 16s │
│   the-architect                            │
└────────────────────────────────────────────┘
```

Native Swift built on macOS 26 Liquid Glass, no dock icon, floats above other apps including
full-screen ones, and never takes keyboard focus when you click it.

The window itself draws nothing. Each row is its own Liquid Glass shape inside a
`GlassEffectContainer`, spaced closely enough that they merge into a single continuous surface
and then fluidly separate and reflow as runs start and finish. State is carried by a faint tint
in the glass rather than by borders or labels, kept subtle because neighbouring rows blend where
they meet.

## Build and run

```bash
scripts/build.sh          # compile and assemble build/cursed.app
scripts/run.sh            # launch it
scripts/stop.sh           # quit it
```

Start it automatically at login:

```bash
scripts/install-login-item.sh     # undo with uninstall-login-item.sh
```

You can also right-click the window to quit, and drag it anywhere. Its position is remembered.

## What the states mean

| Indicator | Meaning |
| --- | --- |
| Blue pulsing dot | A run is in flight. The timer counts up live. |
| Amber ring | The run is still open but Cursor has not touched it in 4 minutes. Usually a crash or a window closed mid-run. |
| Green check | Finished. The time shown is how long the run took. |
| Red cross | Ended in an error or was aborted. |

Finished conversations stay visible for 10 minutes so a completion is never missed, then
disappear. A completion plays a soft chime and flashes the row.

Clicking a row brings Cursor forward. Cursor only registers deep links for automations and
background agents, so there is no URL that opens one specific chat; if Accessibility permission
happens to be granted, the window matching that conversation's project is raised too.

## How it knows

Cursor keeps conversation state in a SQLite database at

```
~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
```

Two tables matter. `composerHeaders` has one small row per conversation with its name and
timestamps; `cursorDiskKV` holds a JSON blob per conversation under `composerData:<id>`.

The blob carries the field this whole app rests on:

- **`unfinishedRunAt`** is set to the exact moment a run starts and cleared when it ends.
  Non-null means running, and the value is the start time, which is where the live timer
  comes from.
- **`status`** becomes `completed` or `aborted` once the run is over.
- **`subtitle`** is Cursor's own description of recent activity, e.g. `Edited main.swift`.
- **`workspaceIdentifier.uri.fsPath`** gives the project each conversation belongs to.

From `composerHeaders`, `lastUpdatedAt` is when the most recent run began and `checkpointAt`
is a heartbeat written while a conversation is live, which doubles as the finish time of a
completed run and as the liveness check behind the stalled state.

Everything is opened read-only, so Cursor never contends with this app for a write lock.

### What was tried first, and why it was dropped

Cursor also writes a JSONL transcript per conversation under
`~/.cursor/projects/<project>/agent-transcripts/`, and each completed turn is closed with a
`{"type":"turn_ended","status":"success"}` event. That looks like the obvious source, and the
turn boundaries are accurate.

It is not usable for live status: those files are checkpointed, not streamed. Measured against
a conversation making a tool call every few seconds, the transcript went **ten minutes** without
a single write. Anything deriving "is it running" from file modification time reports a busy
agent as idle. The database blob updates continuously and carries an explicit run marker, so it
wins on both accuracy and latency.

## Performance

It is meant to sit on screen all day, so cost was measured rather than assumed:

| | CPU (one core) |
| --- | --- |
| Database poll, 200 iterations | 0.26 ms each — 0.03% at 1 Hz |
| Whole app, tracking two live runs | **~0.5%** |

Polling drops from 1 s to 3 s when nothing is running, and the query is bounded to
conversations touched in the last two hours so it never reads more than a handful of blobs.

The pulsing dot is a Core Animation layer animation rather than SwiftUI's `repeatForever`.
That is not a micro-optimisation: the SwiftUI version re-evaluated the view every frame and
measured **5.9% of a core**, versus 0.97% for the same animation driven by the render server.

## Development

```bash
swift run cursed --list     # print current conversation state and exit
swift run cursed --bench    # time the database poll
swift run cursed --demo     # show one row per state, for judging the design
```

`--snapshot <path>` renders the panel's own view to a PNG. Note that it cannot capture Liquid
Glass, which the window server composites out of process, so it only shows plain content.

Logs go to `~/Library/Logs/cursed.log`, including a line each time a run finishes.

## Limitations

- Local conversations only. Cloud and background agents are not in this database.
- Subagents are excluded; only top-level conversations appear.
- Names come from Cursor's own auto-generated titles, so a brand-new chat may briefly show a
  placeholder before Cursor names it.
