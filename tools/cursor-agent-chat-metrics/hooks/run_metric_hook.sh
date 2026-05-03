#!/usr/bin/env bash
# Arguments: hook event name (must match Cursor hook_event_name values).
set -euo pipefail
METRIC_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/track_agent_metrics.py"
export CURSOR_AGENT_METRICS_EVENT="${1:-}"
exec python3 "$METRIC_SCRIPT"
