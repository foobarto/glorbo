Ship completed work: run tests, commit, and push.

## Steps

1. **Check test status:**
   - Run the test suite (`mix test` or whatever's configured)
   - If tests fail, fix them before proceeding
   - Update `.state/test-status.md` with results

2. **Check code quality:**
   - Run formatter (`mix format --check-formatted`)
   - Run compiler warnings check (`mix compile --warnings-as-errors`)
   - Fix any issues

3. **Review changes:**
   - `git diff` to review what's being committed
   - Ensure no secrets, temp files, or unrelated changes

4. **Commit:**
   - Stage relevant files
   - Write a clear commit message (what and why)
   - Commit

5. **Push:**
   - Push to the current branch

6. **Update state:**
   - Move completed tasks to **Done** in `.state/tasks.md`
   - Update `.state/test-status.md` with final results
   - Append to `.state/activity-log.md`

7. **Report:**
   - Summarize what was shipped
