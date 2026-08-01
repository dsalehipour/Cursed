# cursed

A tiny always-on-top window showing which Cursor conversations are running, how long they have
been at it, and which ones finished while you were looking somewhere else.

```
┌────────────────────────────────────────────┐
│    screenlink                      51m 30s │
│    Mac app performance strategies          │
│                                            │
│    cursed                          31m 12s │
│    Cursor app status window                │
│                                            │
│ ●  the-architect                    4m 16s │
│    Future of architect tools               │
└────────────────────────────────────────────┘
```

Native Swift built on macOS 26 Liquid Glass, no dock icon, floats above other apps including
full-screen ones, and never takes keyboard focus when you click it.

The window itself draws nothing. Each row is its own Liquid Glass shape inside a
`GlassEffectContainer`, spaced closely enough that they merge into a single continuous surface
and then fluidly separate and reflow as runs start and finish. The glass is the `clear` variant,
so there is very little between the text and your desktop.

That transparency sets the visual budget: with almost no scrim to work against, state is carried
by text weight and opacity rather than by colour, and the only mark anywhere on screen is a
single green dot.

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

There are three, and only one of them draws attention:

| Row | Meaning |
| --- | --- |
| Plain dark text, no dot | A run is in flight. The timer counts up live. |
| **Green dot** | It finished and you have not acknowledged it yet. |
| Light grey text, no dot | Old news. You clicked it, you stopped it yourself, or it finished more than 10 minutes ago. |

A completion plays a soft chime. Runs you aborted do not, on the grounds that you cannot have
failed to notice something you stopped by hand. Finished conversations stay listed for 30
minutes, which leaves them a comfortable spell as quiet grey history after the dot goes.

A run Cursor still considers open but has not touched in four minutes is treated as stalled: it
keeps reading as in flight, and drops off the list once it has been cold for 30 minutes.

Clicking a row brings Cursor forward and counts as acknowledging it, so the dot clears
immediately. Cursor only registers deep links for automations and background agents, so there is
no URL that opens one specific chat; if Accessibility permission happens to be granted, the
window matching that conversation's project is raised too.

### Clicking versus dragging

The panel is draggable anywhere on its surface, which fights with rows being clickable. The
obvious approach, `isMovableByWindowBackground`, turns any mouse-down that then travels into a
window drag — and a click on a 46pt row routinely drifts ten points, so most clicks were being
swallowed and the panel nudged sideways instead.

Dragging is a `WindowDragGesture` instead, and each row decides between click and drag by how far
the pointer moved **in screen coordinates**. That detail is the whole trick: while the window is
being dragged it travels with the pointer, so the view-local translation stays near zero and
cannot tell the two apart. Under 20 points is a click, more is a reposition.

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
- **`status`** is `completed` or `aborted` once the run is over. It only means anything at that
  point: while a run is in flight the field reads `aborted`, and it flips to `completed` when the
  run ends cleanly. Over 30 days of local history that is 51 `completed` against a single genuine
  abort, with any others simply being runs that were still going.
- **`subtitle`** is Cursor's own description of recent activity, e.g. `Edited main.swift`. Not
  shown in the panel; `--list` prints it.
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
| Whole app, tracking two live runs | **~0.1%** |

Polling drops from 1 s to 3 s when nothing is running, and the query is bounded to
conversations touched in the last two hours so it never reads more than a handful of blobs.

Nothing on screen animates continuously. An earlier design pulsed a dot while a run was in
flight, which cost **5.9% of a core** as a SwiftUI `repeatForever` animation and 0.97% when
driven by the render server through Core Animation. Removing it entirely was better than either.

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
