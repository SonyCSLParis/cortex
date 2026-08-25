# Bash Recipes — Cortex

Reusable bash snippets for the conductor. Read this file only when you
need one — do not auto-load it at chat start.

---

## Quick status table

```bash
echo "AGENT | STATUS | HEARTBEAT | INBOX_PENDING"
echo "------|--------|-----------|---------------"
for d in ~/cortex/agents/*/; do
  id=$(basename "$d")
  hb=$(cat "$d/heartbeat" 2>/dev/null || echo 0)
  age=$(( $(date +%s) - hb ))
  status=$(cat "$d/status" 2>/dev/null || echo -)
  pending=$(ls "$d/inbox/"*.msg 2>/dev/null | wc -l)
  echo "${id} | ${status} | ${age}s ago | ${pending}"
done
```

---

## Read new responses (sorted, newest last)

```bash
ls -1t ~/cortex/agents/conductor/inbox/*.msg 2>/dev/null | while read f; do
  echo "=== $(basename $f) ==="
  cat "$f"
  echo
done
```

---

## Send a command to a specific agent

```bash
AGENT="host-a"         # target hostname / agent id
TASK="your task here"
PRIORITY=1             # 0=high, 1=normal, 2=low

CORTEX=~/cortex
TS=$(date +%s)
HEX=$(head -c 2 /dev/urandom | xxd -p)
MSG_ID="${TS}_${HEX}"
DEST="${CORTEX}/agents/${AGENT}/inbox/${PRIORITY}_${TS}_${HEX}.msg"

cat > "${DEST}.tmp" << EOF
MSG_ID: ${MSG_ID}
FROM:   conductor
TO:     ${AGENT}
TYPE:   COMMAND
TIME:   ${TS}
REF:    none
STATUS: pending
---
${TASK}
EOF
mv "${DEST}.tmp" "${DEST}"
echo "Queued ${MSG_ID} → ${AGENT}"
```

---

## Queue a directive to the watch agent inbox

The watch agent drains `agents/watch/inbox/` at the start of every wake and
injects conductor-queued bodies as `CONDUCTOR_DIRECTIVES`. Messenger ingress is
separate: Signal and Telegram inbox daemons write to `inboxes/signal/` and
`inboxes/telegram/`, which the wrapper exposes to watch as `SIGNAL_INBOUND`
(never addressable from this recipe).
**Body must follow a `---` line** — a blank line alone is not parsed as a
separator.

```bash
DIRECTIVE="your instruction here"

CORTEX=~/cortex
TS=$(date +%s)
HEX=$(head -c 2 /dev/urandom | xxd -p)
MSG_ID="${TS}_${HEX}"
DEST="${CORTEX}/agents/watch/inbox/${TS}_${HEX}.msg"

cat > "${DEST}.tmp" << EOF
MSG_ID: ${MSG_ID}
FROM:   conductor
TO:     watch
TYPE:   COMMAND
TIME:   ${TS}
---
${DIRECTIVE}
EOF
mv "${DEST}.tmp" "${DEST}"
echo "Queued ${MSG_ID} → watch inbox"
```

---

## Broadcast to all agents

```bash
TASK="your broadcast message"
TS=$(date +%s)
HEX=$(head -c 2 /dev/urandom | xxd -p)
MSG_ID="${TS}_${HEX}"
DEST=~/cortex/broadcast/${TS}_${MSG_ID}.msg

cat > "${DEST}.tmp" << EOF
MSG_ID: ${MSG_ID}
FROM:   conductor
TO:     broadcast
TYPE:   BROADCAST
TIME:   ${TS}
REF:    none
STATUS: pending
---
${TASK}
EOF
mv "${DEST}.tmp" "${DEST}"
echo "Broadcast ${MSG_ID} queued"
```

---

## Start a node agent (canonical form — restart loop)

Always launch node agent screens with a restart loop so the screen
survives agent restarts. Never run `scripts/start_agent.sh` as a one-shot command
inside a screen.

```bash
HOST=host-a
ssh ${HOST} "screen -dmS node_${HOST} bash -lc '
  cd ~/cortex && exec > >(tee -a /tmp/node_${HOST}.log) 2>&1
  while true; do
    bash ~/cortex/scripts/start_agent.sh --role node --name ${HOST}
    echo \"[cortex] node_${HOST} agent exited, restarting in 65s...\"
    sleep 65
  done
'"
```

The 65 s sleep exceeds the 60 s heartbeat-stale threshold so the guard
inside `scripts/start_agent.sh` does not reject the restart.

---

## Restart a node agent (without touching the screen)

Never `screen -X quit` to restart an agent — that kills the screen too.
Just kill the inner `scripts/start_agent.sh` process; the screen's restart loop
relaunches it after ~65 s.

```bash
HOST=host-a
ssh ${HOST} "pkill -f '^bash .*/start_agent\.sh --role node\b'"
# agent restarts automatically in ~65s inside the same screen session
```

Do **not** use the broader `pkill -f scripts/start_agent.sh` — that pattern also
matches the outer `bash -lc '... while true; do bash ~/cortex/scripts/start_agent.sh ...'`
wrapper loop and any co-resident worker invocations, which would tear down the
screen and leave nothing to relaunch. The role-anchored
`^bash .*/start_agent\.sh --role node\b` pattern matches only the inner
absolute-path node invocation
(`bash /abs/path/to/cortex/scripts/start_agent.sh --role node --name <host>`)
that the loop spawns, and never matches workers (`--role worker --name <id>`).
See the worker recipe below for argful worker invocations.

---

## Restart a worker

Worker screens, unlike node agents, are launched **without** a
`while true; do … sleep 65; done` restart loop (per `SHORTCUTS.md`), so
killing the inner `scripts/start_agent.sh` exits the screen. Restart by quitting
the screen and relaunching with the generic screen-start helper:

```bash
WORKER=commit   # or cleanup, efficiency, backup, consistency, privacy, security, compressor, reliability, memory, metacortex, calibration, environment
bash scripts/start_agent_screen.sh --role worker --name "${WORKER}" --restart
```

For workers with non-default launch flags, pass them to
`scripts/start_agent_screen.sh` (for example `--provider claude`).

To restart **all** local workers at once:

```bash
for W in backup calibration cleanup commit compressor consistency efficiency environment memory metacortex privacy reliability security; do
  bash scripts/start_agent_screen.sh --role worker --name "${W}" --restart
done
```

---

## Start the supervisor / student loop

Launch the review/repair pair in either order:

```bash
bash scripts/start_agent_screen.sh --role worker --name supervisor
bash scripts/start_agent_screen.sh --role worker --name student
```

Then set the live mission contract:

```bash
cat > ~/cortex/agents/supervisor/mission.txt <<'EOF'
SCOPE:
- exact repo / paths to inspect

MAX_LOOPS:
- unlimited, or a positive integer round cap

OBJECTIVE:
- desired end state

CONSTRAINTS:
- things not to touch

VERIFY:
- tests / checks to run if feasible

DONE_WHEN:
- explicit stop condition
EOF
```

`supervisor` rereads `mission.txt` on every periodic wake, dispatches a
small round to `student`, and waits. `student` implements that round and
wakes `supervisor` again with a structured handoff. If `MAX_LOOPS: <N>`
is set, the supervisor stops dispatching new rounds after `N` student
rounds and marks the mission `capped` unless it already reached
`DONE_WHEN`.

Each supervisor round should include a `WRITABLE_PATHS:` block naming
the exact existing files/directories `student` may write during that
round. The launcher derives a fresh per-round sandbox from that list;
older rounds that only name `TARGETS:` still work as a compatibility
fallback, but new ones should use `WRITABLE_PATHS:` explicitly.

---

## Archive read responses

```bash
mkdir -p ~/cortex/agents/conductor/archive
mv ~/cortex/agents/conductor/inbox/*.msg ~/cortex/agents/conductor/archive/ 2>/dev/null
```

---

## Add a Signal or Telegram auto-reply rule for an external sender

Use the structured reply rule exactly as defined in `roles/all.instruct`.
No extra prose override line is required.

For Signal:

```
SIGNAL_REPLY: <sender-number-or-group-id> → <reply text>
```

For Telegram:

```
TELEGRAM_REPLY: <numeric-user-or-chat-id> → <reply text>
```

The reply text is sent verbatim on the same channel. For Signal groups,
match on the group id rather than an individual sender number.
Gotcha: with the default strict messenger ingress, only incoming
messages whose text/caption starts with `crtx:` are written into the
Signal/Telegram inboxes at all, so auto-reply rules do not see ordinary
non-`crtx:` traffic.

---

## Send a Signal alert via the configured relay

```bash
MESSAGE="Cortex alert: relay-host self-check flagged OOM on run abc123"

if [[ "$(hostname)" == "<signal-relay-host>" ]]; then
  ~/.local/bin/signal-cli -a <signal-account> send -m "${MESSAGE}" <recipient-number>
else
  ssh <signal-relay-host> "~/.local/bin/signal-cli -a <signal-account> send -m '${MESSAGE}' <recipient-number>"
fi
```

Use the current environment notes for the relay host and use
`users/<user>/<user>.instruct` for user-specific identifiers.

---

## Send the User a Telegram alert (any host)

Telegram is the noisier channel — bot DMs reliably trigger mobile push
notifications. Use it for things the user must see promptly. Use the
current environment notes for the local secrets-file path and
`users/<user>/<user>.instruct` for user-specific identifiers.

```bash
MESSAGE="Cortex alert: relay-host self-check flagged OOM on run abc123"

set -a; . <telegram-secrets-file>; set +a
python ~/cortex/scripts/telegram_send.py "${MESSAGE}"
```

Stdin works too — handy when the message comes from a pipeline:

```bash
tail -n 20 some.log | python ~/cortex/scripts/telegram_send.py -
```

For a silent send (no push), pass `--disable-notification`. To send to a
different chat (a contact or group), pass `--chat-id <id>`.
