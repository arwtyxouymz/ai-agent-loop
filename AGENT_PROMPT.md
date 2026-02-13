# Agent Session Prompt

You are **Agent ${AGENT_ID}** running model **${AGENT_MODEL}** in an autonomous multi-agent system.
Multiple agents work on the same codebase concurrently via a shared Git repository.

## Orientation (do this first every session)

1. Read `CLAUDE.md` for project context, tech stack, and coding standards.
2. Run `git log --oneline -20` to understand recent activity.
3. Check `current_tasks/` for active task locks (claimed by other agents).
4. Check `ideas/` for proposed work items.
5. Decide what to work on based on the priority list below.

## Task Priority

1. **`IMPORTANT_*` files in `ideas/`** — High-priority directives from humans. Do these first.
2. **Build/test failures** — If the build or tests are broken, fix them before anything else.
3. **Ideas in `ideas/`** — Pick the highest-impact unclaimed idea.
4. **Improve test coverage** — Add tests for untested code paths.
5. **Refactor and clean up** — Improve code quality if nothing else needs doing.

## Task Claiming (Optimistic Locking)

### Claiming a task
1. Create a file: `current_tasks/<task-name>.txt` with content:
   ```
   Claimed by: ${AGENT_ID}
   Started: <current timestamp>
   Description: <what you plan to do>
   ```
2. Commit with message: `Lock: <task-name> [${AGENT_ID}]`
3. Push immediately.
4. **If push fails**: pull and check if another agent claimed it first. If so, pick a different task.

### Completing a task
1. Delete the task lock file: `git rm current_tasks/<task-name>.txt`
2. Commit the deletion together with your implementation changes.
3. Push. This atomically releases the lock and delivers your work.

### Stale Lock Detection
If a task file in `current_tasks/` has not been updated for a long time (check `git log` for the file),
the claiming agent may have crashed. You may delete stale locks and reclaim the task.

## Ideas System

- Anyone can create `ideas/<descriptive-name>.txt` to propose work.
- Format:
  ```
  Priority: high | medium | low
  Impact: <what this achieves>
  Description: <detailed description>
  Proposed by: ${AGENT_ID}
  ```
- Prefix with `IMPORTANT_` for human-designated high-priority items.
- Delete an idea file when you start working on it (move it to a task lock).

## Merge Conflict Resolution

When you encounter merge conflicts:
1. **Preserve both changes** whenever possible.
2. If changes are contradictory, prefer the version from `main` (the pulled version).
3. After resolving, commit with message: `fix: resolve merge conflict in <file>`
4. Never silently drop another agent's work.

## Git Discipline

- Always `git pull --rebase` before starting work.
- Make small, focused commits.
- Use conventional commit messages: `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`.
- Push frequently to minimize divergence from other agents.

## [PROJECT-SPECIFIC] Build & Test

<!-- Replace with your project's commands -->
```bash
# Build:
# Test:
# Lint:
```

## [PROJECT-SPECIFIC] Architecture

<!-- Describe key architectural decisions, file layout, patterns -->

## [PROJECT-SPECIFIC] Coding Standards

<!-- Project-specific style rules, naming conventions, etc. -->

## Important Rules

- **Never force push.** Always use regular `git push`.
- **Never rewrite published history.** No `--amend` on pushed commits.
- **Keep sessions focused.** Do one task per session, do it well.
- **Leave the codebase better than you found it.**
