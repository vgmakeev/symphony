## Context

Mini owns durable work-item state and exposes a bounded prepared projection.
Symphony already provides the single-agent workspace, retry loop, App Server
protocol and server-bound dynamic tools used by other Economic OS trackers.

## Goals / Non-Goals

**Goals:**

- run one prepared Telegram work item as one Codex agent;
- bind all reads, telemetry and submission to the current tracker issue;
- return only a typed result or human interaction.

**Non-Goals:**

- Telegram delivery, recipient selection or approval execution;
- general Economic OS CRUD or a new scheduler;
- reuse or modification of existing management/PR tracker semantics.

## Decisions

### Dedicated tracker and tool

Use `economic_os_telegram_work_item` rather than branching inside either
existing Economic OS adapter. It calls work-item-specific endpoints and
advertises only `economic_os_submit_telegram_work_item`.

### Server-bound authority

The model cannot supply work-item id, recipient id or Telegram chat id. Symphony
takes the current issue id, validates the bounded result shape and forwards the
pair to Mini. Mini revalidates manifest digest and owns every state transition.

### Retry and human wait

Symphony run attempts remain internal attempts of the same work item. An
`awaiting_human` submission completes the current run; later continuation is a
new bounded run after Mini persists the exact answer.

## Risks / Trade-offs

- A tracker/API schema drift fails closed at submission or refresh.
- The dedicated process adds one small deployment unit but isolates rollout and
  rollback from established Symphony workloads.

## Migration Plan

Deploy the adapter, run contract tests, install a distinct token/config and
start the dedicated unit only after Mini endpoints are live. Roll back by
stopping the unit; Mini retains work items and audit evidence.
