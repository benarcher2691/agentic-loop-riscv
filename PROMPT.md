Read AGENTS.md and follow its workflow for exactly ONE task.

Steps:
1. `make check` — if red, fix first.
2. Open TASKS.md. Take the first `- [ ]` task. Read PROGRESS.md for notes from earlier sessions.
3. Write the testbench for the acceptance criteria, implement, run `make sim` while iterating and `make check` until green. Read build/*.log on failure.
4. Tick the task in TASKS.md, append to PROGRESS.md, commit.
5. Stop.

If every task in TASKS.md is already checked, reply with the single line
`ALL TASKS DONE` and do nothing else.
