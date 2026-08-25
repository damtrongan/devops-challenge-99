#!/usr/bin/env bash
# Polls a URL until it returns HTTP 200, or fails after the given number of
# attempts. Used as a post-deploy gate for both pipelines.
#
# Usage: healthcheck.sh <url> [max_attempts=10] [sleep_seconds=6]

set -euo pipefail

URL="${1:?usage: healthcheck.sh <url> [max_attempts] [sleep_seconds]}"
MAX_ATTEMPTS="${2:-10}"
SLEEP_SECONDS="${3:-6}"

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$URL" || echo "000")
  echo "Attempt ${attempt}/${MAX_ATTEMPTS}: ${URL} -> HTTP ${HTTP_STATUS}"

  if [ "$HTTP_STATUS" = "200" ]; then
    echo "Health check passed."
    exit 0
  fi

  sleep "$SLEEP_SECONDS"
done

echo "Health check failed after ${MAX_ATTEMPTS} attempts." >&2
exit 1
