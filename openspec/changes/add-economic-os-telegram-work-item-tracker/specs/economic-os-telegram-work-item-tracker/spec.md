## ADDED Requirements

### Requirement: CONTRACT-SYMPHONY-TELEGRAM-WORK-ITEM-TRACKER — Dedicated bounded tracker

Symphony SHALL expose `economic_os_telegram_work_item` as a distinct tracker
kind. It SHALL read only the next prepared work-item projection and exact
current issue state from the dedicated Economic OS endpoints. It MUST NOT alter
the selection or mutation semantics of `economic_os` or
`economic_os_mini_pr_review`.

#### Scenario: Prepared work item is available

- **WHEN** Economic OS returns one running work item with no active attempt
- **THEN** Symphony projects it as one active issue and starts one Codex agent in one workspace

### Requirement: CONTRACT-SYMPHONY-TELEGRAM-SUBMISSION — Server-bound typed result

The tracker SHALL advertise exactly one dynamic tool,
`economic_os_submit_telegram_work_item`. The tool SHALL accept the manifest
digest, outcome, bounded summary, safe artifact/evidence references and nullable
typed human interaction. It MUST reject model-supplied work-item, recipient or
Telegram destination identities.

#### Scenario: Model tries to select a recipient

- **WHEN** tool arguments contain `recipient_person_id`
- **THEN** Symphony rejects the call without invoking the Economic OS submit endpoint

#### Scenario: Valid terminal result

- **WHEN** the model submits a complete schema-bound result for the current issue
- **THEN** Symphony adds the current issue id server-side and sends it with a deterministic idempotency key

### Requirement: FLOW-SYMPHONY-TELEGRAM-RUN-TELEMETRY — Attempts remain work-item-bound

Symphony SHALL record start and finish telemetry through work-item-specific
endpoints. Every retry SHALL retain the same tracker issue/work-item identity;
human waiting SHALL end the current process.

#### Scenario: Codex asks a human

- **WHEN** Codex submits an `awaiting_human` result
- **THEN** the current run terminates and Mini owns delivery and any later bounded continuation
