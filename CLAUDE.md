# Project Configuration (Seeded into Bare Repo)

## Directory Structure

- `current_tasks/` — Active task lock files. An agent claims a task by creating a file here and pushing it. Delete the file when the task is complete.
- `ideas/` — Proposals and feature ideas. Any agent can create an idea file for others to pick up. Files prefixed with `IMPORTANT_` are high-priority human directives.

## Git Workflow

- **Branch**: All work happens on `main`. No feature branches.
- **Rebase preferred**: Always `git pull --rebase` before pushing.
- **Atomic commits**: Each commit should be a logical unit of work.
- **Commit messages**: Use conventional style — `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`.

## Task Lifecycle

1. Check `current_tasks/` for unclaimed work
2. Check `ideas/` for new proposals (priority: `IMPORTANT_` > others)
3. Claim a task by creating a lock file in `current_tasks/`
4. Implement the task
5. Delete the lock file and push implementation together
6. If push fails (conflict), pull and retry — if task already claimed, pick another

## [PROJECT-SPECIFIC] Tech Stack

<!-- Replace with your project's tech stack -->
- Language:
- Framework:
- Build tool:

## [PROJECT-SPECIFIC] Build & Test Commands

<!-- Replace with your project's commands -->
```bash
# Build
# make build

# Test
# make test

# Lint
# make lint
```

## [PROJECT-SPECIFIC] Architecture

<!-- Describe your project's architecture here -->

## [PROJECT-SPECIFIC] Coding Standards

<!-- Add project-specific coding standards here -->
