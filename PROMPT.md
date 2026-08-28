Read AGENTS.md and follow its workflow for exactly ONE task.

Steps:
1. `make check` — if red, fix first.
2. Open TASKS.md. Take the first `- [ ]` task. Read PROGRESS.md for notes from earlier sessions.
3. **Act, do not plan.** Right after reading the task, your very next tool call creates the bench file with its first two or three checks and a `make sim` run. Do not design the whole task in your head first; grow the bench and the RTL in small steps, running `make sim` after each (it takes seconds). Think in files, not in thoughts.
4. Keep going until `make check` is green. Read build/*.log on failure.
5. Tick the task in TASKS.md, append to PROGRESS.md, commit.
6. Stop.

If every task in TASKS.md is already checked, reply with the single line
`ALL TASKS DONE` and do nothing else.
