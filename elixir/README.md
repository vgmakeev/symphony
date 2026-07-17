# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls a configured tracker for candidate work: Linear, in-memory test data, or local file tasks
   (`.md`, `.yaml`, `.yml`)
2. Creates an isolated workspace per task, either as a directory or as a Git worktree from a source
   repository
3. Optionally starts a task-scoped Docker Compose project and exposes per-task Playwright env vars
4. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
5. Sends a workflow prompt to Codex
6. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves a client-side `linear_graphql` tool so that repo
skills can make raw Linear GraphQL calls.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
mise exec -- ./bin/symphony /path/to/project
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

You can also pass a project directory. Symphony will use `<project>/WORKFLOW.md` and resolve
project-relative configuration paths from that directory:

```bash
./bin/symphony /path/to/project
```

If no path is passed, Symphony defaults to `./WORKFLOW.md` in the current directory, with the
current directory as the project root.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)
- `--project-root` overrides the project root when the workflow file lives outside the project

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Local file tracker with Git worktree, Compose, and Playwright isolation:

```yaml
tracker:
  kind: file
  tasks_dir: ./backlog/tasks
  active_states: [Todo, In Progress, Rework]
  terminal_states: [Done, Cancelled]
workspace:
  root: ~/code/symphony-workspaces
  strategy: git_worktree
  source: ~/code/my-repo
  base_ref: main
  branch_prefix: symphony/
compose:
  enabled: true
  project_name_prefix: symphony
  file: compose.yaml
  up: up -d --build
  down: down --remove-orphans --volumes
playwright:
  isolated: true
  browsers_path: .playwright-browsers
```

Notes:

- If a value is missing, defaults are used.
- Relative paths in `tracker.tasks_dir`, `workspace.root`, and `workspace.source` resolve from the
  project root, not from the Symphony checkout. The project root defaults to the directory passed to
  `./bin/symphony`, or to the directory containing `WORKFLOW.md` when a workflow file path is passed.
  A workflow can override it with `project.root`, and the CLI can override it with `--project-root`.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- Supported `codex.turn_sandbox_policy.type` values: `dangerFullAccess`, `readOnly`,
  `externalSandbox`, `workspaceWrite`.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- Use `workspace.strategy: git_worktree` with a local Git repository in `workspace.source` to create
  one Git worktree and branch per task without recloning the repository.
- When `compose.enabled` is true, Symphony runs `docker compose` with a deterministic
  `COMPOSE_PROJECT_NAME` derived from the task identifier. Hooks and agent subprocesses receive the
  same `COMPOSE_PROJECT_NAME`, `SYMPHONY_COMPOSE_PROJECT_NAME`, `SYMPHONY_WORKSPACE`,
  `SYMPHONY_ISSUE_ID`, and `SYMPHONY_ISSUE_IDENTIFIER` variables.
- When `playwright.isolated` is true, hooks and agent subprocesses receive
  `PLAYWRIGHT_BROWSERS_PATH` and `SYMPHONY_PLAYWRIGHT_BROWSERS_PATH` rooted under the task
  workspace by default.
- `tracker.kind: file`, `markdown`, `yaml`, and `yml` all use the local file tracker. Markdown tasks
  use YAML front matter; YAML tasks use the same fields directly plus optional `description`.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN app-server --model gpt-5.3-codex"
```

- If `WORKFLOW.md` is missing or has invalid YAML, startup and scheduling are halted until fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
