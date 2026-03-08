#!/bin/bash
cd "$(dirname "$0")"
mise exec -- ./bin/symphony ./WORKFLOW_MARKDOWN.md --i-understand-that-this-will-be-running-without-the-usual-guardrails --port 4000
