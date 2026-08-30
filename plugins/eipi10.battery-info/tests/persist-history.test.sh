#!/usr/bin/env bash

set -euo pipefail

plugin_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
writer="$plugin_dir/persist-history.sh"
test_root=$(mktemp -d)
state_dir="$test_root/state"

cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT HUP INT TERM

first_payload="{\"writer\":\"first\",\"value\":\"apostrophe: ' and newline:\\n\"}"
second_payload='{"writer":"second"}'

"$writer" "$state_dir" "$first_payload"
"$writer" "$state_dir" "$second_payload"

[[ $(<"$state_dir/history.json") == "$second_payload" ]]
[[ $(<"$state_dir/history.json.bak") == "$first_payload" ]]

pids=()
for writer_id in $(seq 1 24); do
  "$writer" "$state_dir" "{\"writer\":$writer_id}" &
  pids+=("$!")
done

for pid in "${pids[@]}"; do
  wait "$pid"
done

node -e '
  const fs = require("node:fs")
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
  if (!Number.isInteger(value.writer) || value.writer < 1 || value.writer > 24) {
    process.exit(1)
  }
' "$state_dir/history.json"

if compgen -G "$state_dir/.history.json.tmp.*" >/dev/null; then
  echo "temporary history files were not cleaned up" >&2
  exit 1
fi

echo "battery-info persistence tests passed"
