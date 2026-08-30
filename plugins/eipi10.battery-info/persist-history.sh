#!/usr/bin/env bash

set -euo pipefail

if (( $# != 2 )); then
  echo "usage: persist-history.sh HISTORY_DIR JSON_PAYLOAD" >&2
  exit 64
fi

history_dir=$1
payload=$2
history_path="$history_dir/history.json"
backup_path="$history_dir/history.json.bak"
lock_path="$history_dir/history.lock"
temporary_path=

cleanup() {
  if [[ -n $temporary_path ]]; then
    rm -f -- "$temporary_path"
  fi
}
trap cleanup EXIT HUP INT TERM

mkdir -p -- "$history_dir"

# Every monitor owns a widget instance, and old/new Quickshell generations can
# coexist briefly during a hot reload. Serialize those boundaries even though
# the QML side normally designates one screen as the writer.
exec 9>"$lock_path"
flock -x 9

temporary_path=$(mktemp "$history_dir/.history.json.tmp.XXXXXX")
printf '%s' "$payload" >"$temporary_path"

if [[ -f $history_path ]]; then
  cp -p -- "$history_path" "$backup_path"
  chmod --reference="$history_path" "$temporary_path"
else
  chmod 600 "$temporary_path"
fi

mv -f -- "$temporary_path" "$history_path"
temporary_path=
