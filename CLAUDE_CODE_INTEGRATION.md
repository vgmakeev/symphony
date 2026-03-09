# Symphony → Claude Code: план интеграции

## Контекст

Форк [openai/symphony](https://github.com/openai/symphony) — Elixir/OTP оркестратор, который поллит трекер задач, создаёт изолированные workspace'ы и запускает кодинг-агентов. Оригинал использует Codex app-server (JSON-RPC 2.0 over stdio). Мы заменяем Codex на Claude Code CLI.

Референс: [dohyun-ko/symphony-claude-code](https://github.com/dohyun-ko/symphony-claude-code) — рабочий форк, но с рядом недостатков (см. ниже).

## Уже сделано

- **Markdown tracker** (`elixir/lib/symphony_elixir/tracker/markdown.ex`) — файловый трекер в формате [Backlog.md](https://github.com/MrLesk/Backlog.md), заменяет Linear
- **Auto state management** в `agent_runner.ex` — Todo → In Progress → Review
- **WORKFLOW_MARKDOWN.md** — промпт-шаблон для агента, адаптированный под markdown tracker
- Тестовый прогон (task-1, аптечный поиск) — успешно завершён Codex'ом

## Реализовано ✅

### `lib/symphony_elixir/claude_code.ex` — новый модуль

Заменяет `Codex.AppServer`. Основные решения:

**Вызов:**
```bash
printf '%s' "$_SYMPHONY_PROMPT" | claude -p \
  --output-format stream-json \
  --verbose \
  --session-id <session_id> \
  --resume \
  --permission-mode bypassPermissions \
  --max-turns 50
```

- Промпт передаётся через env var `_SYMPHONY_PROMPT`, пайпится в stdin через `printf` — **zero shell injection risk**
- `--session-id` + `--resume` — контекст сохраняется между turns
- Prompt caching не отключаем
- Workspace задаётся через `cd:` в Erlang Port
- Graceful shutdown: `SIGTERM` → ожидание 15s → `SIGKILL`

**Парсинг stream-json:**

| type | Событие | Действие |
|------|---------|----------|
| `system` (subtype `init`) | `:system_init` | Извлечь `session_id` для resume |
| `assistant` | `:assistant_message` | Извлечь `message.usage` (токены) |
| `tool_use` | `:tool_use` | Для дашборда |
| `tool_result` | `:tool_result` | Для дашборда |
| `result` + `success` | `:turn_completed` | Финал. `usage`, `total_cost_usd`, `duration_ms`, `num_turns` |
| `result` + `error` | `:turn_failed` | Ошибка |

Все события прокидываются через `on_message` callback.

### `lib/symphony_elixir/agent_runner.ex` — обновлён

- `AppServer.start_session/run_turn/stop_session` → `ClaudeCode.run/4`
- `session_id` передаётся между turns для `--resume`
- Turn 1: полный промпт, turn 2+: continuation guidance
- Остальная логика (DONE.md, state checking, markdown tracker) без изменений

### `lib/symphony_elixir/config.ex` — обновлён

- Дефолтная команда: `"claude"` (было `"codex app-server"`)
- `validate!/0`: убрана проверка `codex_runtime_settings` (approval_policy, sandbox — не нужны для Claude Code)

### `lib/symphony_elixir/orchestrator.ex` — обновлён

- Добавлена поддержка `claude_code_pid` в `codex_app_server_pid_for_update`
- Парсинг токенов уже совместим: `extract_token_usage` обрабатывает flat `input_tokens`/`output_tokens`

### Что НЕ нужно (подтверждено)

- **Bidirectional approval flow** — `--permission-mode bypassPermissions` решает
- **Dynamic tools через оркестратор** — Claude Code нативно поддерживает MCP
- **JSON-RPC протокол** — stream-json проще и достаточен

## Преимущества над референсом (dohyun-ko)

1. **Session resume** ✅ — `--session-id` + `--resume` сохраняют контекст
2. **Безопасные permissions** ✅ — `--permission-mode bypassPermissions` вместо `--dangerously-skip-permissions`
3. **Prompt caching** ✅ — не отключаем, экономия ×5 на токенах
4. **Нет shell injection** ✅ — промпт через env var, не в аргументах
5. **Graceful shutdown** ✅ — SIGTERM → 15s timeout → SIGKILL

## Архитектура (итог)

```
Orchestrator (GenServer)
  │
  ├── poll markdown tracker каждые N секунд
  ├── для каждого активного таска:
  │     AgentRunner (Task.Supervisor)
  │       │
  │       ├── Workspace.create_for_issue (mkdir, git init)
  │       ├── ClaudeCode.run(workspace, prompt, session_id, opts)
  │       │     └── Erlang Port: claude -p --stream-json --session-id X
  │       │           └── stdout → parse JSON lines → on_message callback
  │       ├── (если issue ещё active) ClaudeCode.run(..., --resume)
  │       └── maybe_move_to_review (если есть коммиты или DONE.md)
  │
  └── Phoenix LiveView Dashboard (порт 4000)
        └── отображает events, токены, статусы в реальном времени
```
