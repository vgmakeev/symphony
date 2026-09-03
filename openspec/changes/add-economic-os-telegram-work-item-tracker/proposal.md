## Why

Economic OS can prepare durable Telegram work items, but the existing Symphony
trackers understand only management agendas and Mini PR reviews. A dedicated
adapter is required so long Telegram tasks run through the trusted Symphony
executor without changing either existing lifecycle.

## What Changes

- Add tracker kind `economic_os_telegram_work_item` with dedicated next/get,
  result-submission and run-telemetry endpoints.
- Expose exactly one server-bound dynamic tool for a bounded terminal result or
  typed human request.
- Keep work-item identity, recipient routing, Telegram delivery and business
  lifecycle in Economic OS.

## Capabilities

### New Capabilities

- `economic-os-telegram-work-item-tracker`: bounded Symphony execution of one
  prepared Telegram work item.

### Modified Capabilities

- None.

## Impact

- Adds one tracker adapter, one dynamic tool schema and tracker-aware runtime
  selection/run telemetry.
- Does not alter `economic_os` or `economic_os_mini_pr_review` semantics.
