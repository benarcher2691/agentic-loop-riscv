#!/usr/bin/env bash
# The OUTER agentic loop (v2).
#
#   ./loop.sh [max_iterations]
#
# Each iteration starts a brand-new agent session (fresh context) with the same
# prompt. The only state carried between iterations is what is on disk:
# TASKS.md, PROGRESS.md, the code, and git history. The loop stops when TASKS.md
# has no unchecked task, after max_iterations, or when it is clearly stuck.
#
# Knobs (environment variables, all optional):
#   MODEL         model for the default runner       (openrouter/z-ai/glm-5.3-flash)
#   RUN           runner command; the prompt is appended as the last argument.
#                 default: opencode run --agent loop --model $MODEL --auto --title <session>
#                 e.g.     RUN="codex exec --full-auto" ./loop.sh
#   ITER_TIMEOUT  seconds before an iteration is killed              (1800)
#   STUCK_LIMIT   stop after N consecutive iterations with no progress on the same task (3)
#   MIN_SECONDS   an iteration shorter than this that made no progress is a DUD — the model
#                 returned without acting (empty/text-only turn). Duds are retried and do not
#                 count toward STUCK_LIMIT; DUD_LIMIT consecutive duds stop the loop.  (30 / 3)
#   ON_RED        keep | revert — uncommitted changes after a non-green iteration (keep)
#   CHECK_CMD     the verifier; default: `make -s check` if a Makefile exists, else `npm run -s check`
#   TEST_COUNT_RE regex whose last number is the passing-test count
#                 (default matches vitest's "Tests N passed" and this kit's "CHECKS TOTAL: N")
#   PROGRESS      the agent's memory file                                  (PROGRESS.md)
#   HANDOFF       1 = when a session ends without ticking its task, append its last
#                 message to PROGRESS so the next session inherits the context (1)
#   PROGRESS_KEEP keep only the newest N entries in PROGRESS; older ones move to
#                 PROGRESS-archive.md before each session (context hygiene)        (6)
#   TASKS_KEEP_DONE keep only the newest N ticked tasks in TASKS; older ticked ones
#                 move to TASKS-done.md before each session                        (2)
#   Per-task model: a task line may end with  <!-- model: provider/model -->  to run
#                 that one task on a different model (default runner only).
#   TASKS, PROMPT task file / prompt file                            (TASKS.md / PROMPT.md)
#
# Exit codes: 0 all tasks done, 1 setup problem, 2 max iterations, 3 stuck, 4 repeated duds.
set -uo pipefail
cd "$(dirname "$0")"

MAX=${1:-10}
MODEL=${MODEL:-openrouter/z-ai/glm-5.3-flash}
ITER_TIMEOUT=${ITER_TIMEOUT:-1800}
STUCK_LIMIT=${STUCK_LIMIT:-3}
MIN_SECONDS=${MIN_SECONDS:-30}
DUD_LIMIT=${DUD_LIMIT:-3}
ON_RED=${ON_RED:-keep}
TASKS=${TASKS:-TASKS.md}
PROMPT=${PROMPT:-PROMPT.md}
if [[ -z "${CHECK_CMD:-}" ]]; then
  if [[ -f Makefile ]]; then CHECK_CMD="make -s check"; else CHECK_CMD="npm run -s check"; fi
fi
TEST_COUNT_RE=${TEST_COUNT_RE:-Tests +[0-9]+ passed|CHECKS TOTAL: [0-9]+}
PROGRESS=${PROGRESS:-PROGRESS.md}
HANDOFF=${HANDOFF:-1}
PROGRESS_KEEP=${PROGRESS_KEEP:-6}
TASKS_KEEP_DONE=${TASKS_KEEP_DONE:-2}
RUN=${RUN:-}

RUN_ID=$(date +%Y%m%d-%H%M%S)
RUN_DIR=runs/$RUN_ID
LOG=loop.log
DB=$HOME/.local/share/opencode/opencode.db
SUMMARY=$RUN_DIR/summary.tsv
mkdir -p "$RUN_DIR"

log()          { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG" "$RUN_DIR/loop.log"; }
remaining()    { grep -c '^- \[ \]' "$TASKS" || true; }
current_task() { grep -m1 '^- \[ \]' "$TASKS" | cut -c7-70; }
dirty()        { [[ -n "$(git status --porcelain)" ]]; }

# Runs the verifier, prints the passing-test count, returns its exit code.
check() {
  local out rc
  out=$(eval "$CHECK_CMD" 2>&1); rc=$?
  grep -oE "$TEST_COUNT_RE" <<<"$out" | tail -1 | grep -oE '[0-9]+' || echo 0
  return $rc
}

# turns, input, output, reasoning, cache_read, cost for a session title (tab-separated).
# Only works with the default opencode runner; prints dashes otherwise.
session_stats() {
  local title=$1
  command -v sqlite3 >/dev/null && [[ -f "$DB" ]] || { printf -- '-\t-\t-\t-\t-\t-\n'; return; }
  sqlite3 -separator $'\t' "$DB" "
    select count(*),
      ifnull(sum(json_extract(m.data,'\$.tokens.input')),0),
      ifnull(sum(json_extract(m.data,'\$.tokens.output')),0),
      ifnull(sum(json_extract(m.data,'\$.tokens.reasoning')),0),
      ifnull(sum(json_extract(m.data,'\$.tokens.cache.read')),0),
      round(ifnull(sum(json_extract(m.data,'\$.cost')),0),4)
    from message m join session s on s.id = m.session_id
    where s.title = '$title' and json_extract(m.data,'\$.role') = 'assistant';" 2>/dev/null \
    || printf -- '-\t-\t-\t-\t-\t-\n'
}

# Context hygiene: the agent reads TASKS and PROGRESS in full every session, and both
# grow without bound. Rotate old material into archive files the agent is told about
# but does not read by default. A block is a top-level "- " line plus its continuation
# lines up to the next blank line.
rotate_files() {
  command -v python3 >/dev/null || return 0
  python3 - "$PROGRESS" "$PROGRESS_KEEP" "$TASKS" "$TASKS_KEEP_DONE" <<'PY'
import os, sys

def split_blocks(text):
    # returns (preamble_lines, blocks); a block is a list of lines starting with a '- ' line
    pre, blocks, cur = [], [], None
    for ln in text.split("\n"):
        if ln.startswith("- "):
            if cur is not None: blocks.append(cur)
            cur = [ln]
        elif cur is not None and (ln == "" or ln[:1] in (" ", "\t")):
            cur.append(ln)
        else:
            if cur is not None: blocks.append(cur); cur = None
            if not blocks: pre.append(ln)
            else: blocks.append([ln])          # heading or prose between blocks: keep in place
    if cur is not None: blocks.append(cur)
    return pre, blocks

def render(pre, blocks):
    out = "\n".join(pre).rstrip("\n") + "\n\n"
    for b in blocks:
        out += "\n".join(b).rstrip("\n") + "\n\n"
    return out

def archive(path, header, blocks):
    new = not os.path.exists(path) or os.path.getsize(path) == 0
    with open(path, "a") as f:
        if new: f.write(header)
        for b in blocks: f.write("\n".join(b).rstrip("\n") + "\n\n")

def rotate_progress(path, keep):
    if not os.path.exists(path): return
    pre, blocks = split_blocks(open(path).read())
    entries = [b for b in blocks if b[0].startswith("- ")]
    if len(entries) <= keep: return
    old = entries[:-keep]
    arch = path[:-3] + "-archive.md"
    archive(arch, "# Progress archive (rotated out of %s by loop.sh; oldest first)\n\n" % path, old)
    open(path, "w").write(render(pre, [b for b in blocks if b not in old]))
    print("rotated %d PROGRESS entries to %s" % (len(old), arch))

def rotate_tasks(path, keep_done):
    if not os.path.exists(path): return
    pre, blocks = split_blocks(open(path).read())
    done = [b for b in blocks if b[0].startswith("- [x]")]
    if len(done) <= keep_done: return
    old = done[:-keep_done]
    arch = path[:-3] + "-done.md"
    archive(arch, "# Completed tasks (moved out of %s by loop.sh; oldest first)\n\n" % path, old)
    open(path, "w").write(render(pre, [b for b in blocks if b not in old]))
    print("moved %d completed tasks to %s" % (len(old), arch))

rotate_progress(sys.argv[1], int(sys.argv[2]))
rotate_tasks(sys.argv[3], int(sys.argv[4]))
PY
}

# The first unchecked task may name its own model:  <!-- model: provider/model -->
task_model() { grep -m1 '^- \[ \]' "$TASKS" | grep -oE '<!-- *model: *[^ >]+ *-->' | sed -E 's/<!-- *model: *([^ >]+) *-->/\1/'; }

# A session that ends without ticking its task often leaves its best notes in its
# final message (e.g. after hitting the step cap, tools are disabled and it cannot
# write PROGRESS itself). Append that message so the next session inherits it.
# Only works with the default opencode runner (reads its session DB).
handoff_note() {   # $1 = session title, $2 = iteration, $3 = status
  (( HANDOFF )) || return 0
  command -v sqlite3 >/dev/null && [[ -f "$DB" ]] || return 0
  local txt
  # last text turns, oldest first, minus the prompt echo and one-line filler
  local prompt; prompt=$(cat "$PROMPT")
  txt=$(sqlite3 -separator $'\x1e' "$DB" "select json_extract(p.data,'\$.text') from (select p.data, p.time_created from part p join session s on s.id = p.session_id
        where s.title = '$1' and json_extract(p.data,'\$.type') = 'text' order by p.time_created desc limit 4) p order by p.time_created;" 2>/dev/null \
        | python3 -c 'import sys; p=sys.argv[1].strip(); parts=[t.strip() for t in sys.stdin.read().split("\x1e")]; keep=[t for t in parts if len(t)>=160 and t.strip(chr(34)) != p and not t.lower().startswith(("let me","now let me","first,","i will","i\x27ll"))]; print("\n\n".join(keep)[:6000])' "$prompt")
  if (( ${#txt} < 200 )); then log "iteration $2: no substantial last message to hand off (${#txt} chars)"; return 0; fi
  {
    printf '\n- **Handoff captured by loop.sh — iteration %s ended without ticking its task (tree: %s). The session'"'"'s last message, verbatim:**\n\n' "$2" "$3"
    printf '%s\n' "$txt" | sed 's/^/  > /'
    printf '\n'
  } >> "$PROGRESS"
  log "iteration $2: captured the session's last message (${#txt} chars) into $PROGRESS for the next session"
}

# One session, killed after ITER_TIMEOUT. Output streams to the terminal and to logs.
run_iteration() {
  local title=$1 prompt start pid
  prompt=$(cat "$PROMPT")
  start=$(date +%s)
  if [[ -n "$RUN" ]]; then
    $RUN "$prompt" > >(tee -a "$LOG" "$RUN_DIR/$title.log") 2>&1 &
  else
    opencode run --agent loop --model "${ITER_MODEL:-$MODEL}" --auto --title "$title" "$prompt" \
      > >(tee -a "$LOG" "$RUN_DIR/$title.log") 2>&1 &
  fi
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if (( $(date +%s) - start > ITER_TIMEOUT )); then
      pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; sleep 2; kill -9 "$pid" 2>/dev/null
      return 124
    fi
    sleep 2
  done
  wait "$pid"
}

finish() {
  local code=$1
  if [[ -s "$SUMMARY" ]]; then
    log "summary ($RUN_DIR/summary.tsv):"
    column -t -s $'\t' "$SUMMARY" | tee -a "$LOG" "$RUN_DIR/loop.log"
    log "totals: iterations=$iterations green=$greens non-green=$reds time=${total_time}s cost=\$$total_cost tasks_left=$(remaining)"
  fi
  exit "$code"
}

# --- preflight -------------------------------------------------------------
if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  echo "No commits yet. Run: git add -A && git commit -m 'scaffold'" >&2; exit 1
fi
[[ -f "$TASKS" && -f "$PROMPT" ]] || { echo "missing $TASKS or $PROMPT" >&2; exit 1; }
[[ "$ON_RED" == keep || "$ON_RED" == revert ]] || { echo "ON_RED must be keep or revert" >&2; exit 1; }

prev_tests=$(check) || log "WARNING: baseline verifier ($CHECK_CMD) is red — the first iteration must fix it (AGENTS.md step 1)"
log "loop start: run=$RUN_ID runner=${RUN:-opencode/$MODEL} max=$MAX timeout=${ITER_TIMEOUT}s stuck_limit=$STUCK_LIMIT on_red=$ON_RED tests=$prev_tests tasks_left=$(remaining)"
printf 'iter\ttask\tstatus\tseconds\ttests\tturns\tinput\toutput\treasoning\tcache_read\tcost\n' > "$SUMMARY"

# --- the loop --------------------------------------------------------------
iterations=0 greens=0 reds=0 stuck=0 duds=0 total_time=0 total_cost=0
for ((i = 1; i <= MAX; i++)); do
  left=$(remaining)
  if (( left == 0 )); then
    log "all tasks checked — loop complete after $((i - 1)) iteration(s)"
    finish 0
  fi
  rotate_files | while read -r l; do log "$l"; done
  task=$(current_task)
  title="loop-$RUN_ID-$i"
  ITER_MODEL=$(task_model); ITER_MODEL=${ITER_MODEL:-$MODEL}
  log "=== iteration $i/$MAX — $left task(s) left — next: $task ==="
  [[ "$ITER_MODEL" != "$MODEL" ]] && log "iteration $i: task requests model $ITER_MODEL"

  start=$(date +%s)
  run_iteration "$title"; rc=$?
  elapsed=$(( $(date +%s) - start ))

  # Independent verification: never trust the agent's own claim of "green".
  tests=$(check); crc=$?
  if   (( rc == 124 )); then status=TIMEOUT
  elif (( crc == 0 ));  then status=green
  else                       status=RED
  fi

  if [[ $status == green ]]; then
    if (( tests < prev_tests )); then
      status=SUSPECT
      log "iteration $i: green but test count dropped $prev_tests -> $tests; not auto-committing"
    elif dirty; then
      git add -A && git commit -qm "loop: iteration $i (auto-commit; agent left changes uncommitted)"
      log "iteration $i: agent left uncommitted changes; committed them"
    fi
  fi
  if [[ $status != green && $ON_RED == revert ]] && dirty; then
    git checkout -- . && git clean -fdq -e loop.log -e runs -e build
    log "iteration $i: reverted uncommitted changes (ON_RED=revert)"
  fi

  no_progress=0; [[ "$(current_task)" == "$task" && -n "$task" ]] && no_progress=1
  if (( no_progress && elapsed < MIN_SECONDS )); then
    status=DUD; (( duds++ )); (( reds++ ))
    log "iteration $i: returned after ${elapsed}s without progress — model ended its turn without acting; retrying"
  else
    duds=0
    if [[ $status == green ]]; then (( greens++ )); else (( reds++ )); fi
    if (( no_progress )); then (( stuck++ )); handoff_note "$title" "$i" "$status"; else stuck=0; fi
  fi
  (( iterations++ )); (( total_time += elapsed ))
  [[ $status == green ]] && prev_tests=$tests   # baseline only advances on a clean green

  stats=$(session_stats "$title")
  cost=$(cut -f6 <<<"$stats")
  total_cost=$(awk -v a="$total_cost" -v b="$cost" 'BEGIN { printf "%.4f", a + b }')
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$task" "$status" "$elapsed" "$tests" "$stats" >> "$SUMMARY"
  log "iteration $i: $status in ${elapsed}s, tests=$tests, cost=\$$cost, tasks_left=$(remaining)"

  if (( duds >= DUD_LIMIT )); then
    log "$duds consecutive iterations ended without acting — stopping (model/provider problem, not a task problem)"
    finish 4
  fi
  if (( stuck >= STUCK_LIMIT )); then
    log "no progress on \"$task\" for $stuck iteration(s) — stopping (split the task or read $RUN_DIR/$title.log)"
    finish 3
  fi
done

log "max iterations ($MAX) reached with $(remaining) task(s) left — stopping"
finish 2
