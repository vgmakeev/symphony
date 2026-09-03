## 1. Tracker boundary

- [x] 1.1 Add the dedicated tracker adapter and configuration selection without changing existing trackers.
- [x] 1.2 Add work-item-bound start/finish telemetry calls and normalized issue projection.

## 2. Typed submission

- [x] 2.1 Add the strict result/human-interaction dynamic tool schema.
- [x] 2.2 Reject model-supplied work-item, recipient and Telegram identities and use deterministic submission idempotency.

## 3. Verification and operations

- [x] 3.1 Cover tracker selection, projection, exact endpoints, telemetry, tool availability and forbidden identity with tests.
- [x] 3.2 Run the full Symphony quality gate and a production canary against the Mini work-item endpoints.
