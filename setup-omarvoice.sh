#!/usr/bin/env bash
#
# Reproducible Omarvoice installation for an Omarchy desktop.
#
# The repository owns code and the static recognition profile. This setup
# installs machine dependencies, derives Antigravity's OAuth client locally,
# runs a fresh browser authorization, and persists only this machine's tokens.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_PLUGIN="${SCRIPT_DIR}/plugins/eipi10.agents"
VOICE_PLUGIN="${SCRIPT_DIR}/plugins/qwen-asr"
AGENT_CTL="${AGENT_PLUGIN}/bin/omarchy-antigravity-ctl"
VOICE_CTL="${VOICE_PLUGIN}/bin/qwen-asr-ctl"
VOICE_BRIDGE="${VOICE_PLUGIN}/bin/omarvoice-antigravity"
LANGUAGE_SERVER="${OMARVOICE_ANTIGRAVITY_LANGUAGE_SERVER:-/opt/Antigravity/resources/bin/language_server}"
MIN_ANTIGRAVITY_VERSION="2.11.0-1"

check_only=false
skip_auth=false
force_auth=false
shortcut="F9"

usage() {
  cat <<'USAGE'
Usage: ./setup-omarvoice.sh [options]

Install and configure the complete Omarvoice + Agent Panel dictation path.

Options:
  --check              Read-only health check; change nothing
  --skip-auth          Install everything but postpone browser authorization
  --reauthorize        Run browser authorization even when an account is ready
  --shortcut <key>     Push-to-talk shortcut (default: F9)
  -h, --help           Show this help

Run this script from an interactive Omarchy desktop terminal. Package
installation may ask for sudo, and browser authorization needs the graphical
session on this machine.
USAGE
}

step() {
  printf '\n[%s] %s\n' "$1" "$2"
}

note() {
  printf '    %s\n' "$1"
}

fail() {
  printf 'Omarvoice setup: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

json_ready() {
  jq -e '.ready == true' >/dev/null 2>&1 <<<"$1"
}

check_symlink() {
  local plugin_id="$1"
  local expected="$2"
  local installed="${HOME}/.config/omarchy/plugins/${plugin_id}"
  [[ -L "$installed" ]] || return 1
  [[ "$(readlink -f "$installed")" == "$(readlink -f "$expected")" ]]
}

check_antigravity_version() {
  local installed_version
  installed_version="$(pacman -Q antigravity 2>/dev/null | awk '{print $2}')"
  [[ -n "$installed_version" ]] || return 1
  (( "$(vercmp "$installed_version" "$MIN_ANTIGRAVITY_VERSION")" >= 0 ))
}

health_check() {
  local mode="${1:-active}"
  local failures=0
  local command_name
  local auth_status=""
  local daemon_status=""

  step "check" "Verifying the complete local path"

  for command_name in \
    omarchy omarchy-shell pacman vercmp pgrep jq git python3 \
    pw-record secret-tool wl-copy wtype; do
    if command -v "$command_name" >/dev/null 2>&1; then
      note "command ${command_name}: ready"
    else
      note "command ${command_name}: missing"
      failures=$((failures + 1))
    fi
  done

  if command -v pacman >/dev/null 2>&1 \
    && command -v vercmp >/dev/null 2>&1 \
    && [[ -x "$LANGUAGE_SERVER" ]] \
    && check_antigravity_version; then
    note "Antigravity language server: ready"
  else
    note "Antigravity 2.11+ language server: missing or unsupported"
    failures=$((failures + 1))
  fi

  if check_symlink "eipi10.agents" "$AGENT_PLUGIN"; then
    note "Agent Panel plugin: linked"
  else
    note "Agent Panel plugin: not linked to this checkout"
    failures=$((failures + 1))
  fi

  if check_symlink "qwen-asr" "$VOICE_PLUGIN"; then
    note "Omarvoice plugin: linked"
  else
    note "Omarvoice plugin: not linked to this checkout"
    failures=$((failures + 1))
  fi

  if [[ "$mode" == "read-only" ]]; then
    if [[ -s "${HOME}/.config/omarchy/agents/antigravity/oauth.json" ]] \
      && [[ -s "${HOME}/.config/omarchy/agents/antigravity/accounts.json" ]] \
      && compgen -G "${HOME}/.config/omarchy/agents/antigravity/auth/*.json" >/dev/null; then
      note "long-lived browser authorization files: present"
    else
      note "long-lived browser authorization files: incomplete"
      failures=$((failures + 1))
    fi
  elif [[ -x "$AGENT_CTL" ]]; then
    auth_status="$("$AGENT_CTL" voice-auth-status 2>/dev/null || true)"
    if [[ -n "$auth_status" ]] && json_ready "$auth_status"; then
      note "long-lived browser authorization: ready"
    else
      note "long-lived browser authorization: not ready"
      failures=$((failures + 1))
    fi
  else
    note "long-lived browser authorization: controller missing"
    failures=$((failures + 1))
  fi

  if [[ "$mode" == "read-only" ]] \
    && pgrep -f -- "${VOICE_PLUGIN}/lib/omarvoice_antigravity.py serve" >/dev/null; then
    note "Omarvoice resident service: running"
  elif [[ "$mode" == "read-only" ]]; then
    note "Omarvoice resident service: not running"
    failures=$((failures + 1))
  elif [[ -x "$VOICE_BRIDGE" ]]; then
    daemon_status="$("$VOICE_BRIDGE" daemon-status 2>/dev/null || true)"
    if [[ -n "$daemon_status" ]] \
      && jq -e '.ready == true and .protocol_version == 8' >/dev/null 2>&1 <<<"$daemon_status"; then
      note "Omarvoice resident service: ready (protocol 8)"
    else
      note "Omarvoice resident service: not ready"
      failures=$((failures + 1))
    fi
  else
    note "Omarvoice resident service: bridge missing"
    failures=$((failures + 1))
  fi

  if (( failures > 0 )); then
    note "health check failed in ${failures} area(s)"
    return 1
  fi
  note "all checks passed"
}

while (( $# > 0 )); do
  case "$1" in
    --check)
      check_only=true
      shift
      ;;
    --skip-auth)
      skip_auth=true
      shift
      ;;
    --reauthorize)
      force_auth=true
      shift
      ;;
    --shortcut)
      [[ -n "${2:-}" ]] || fail "--shortcut requires a key"
      shortcut="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

if "$check_only"; then
  health_check read-only
  exit $?
fi

step "1/7" "Checking the Omarchy host"
require_command omarchy
require_command omarchy-shell
require_command pacman
require_command vercmp
[[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] \
  || fail "run setup inside the logged-in Omarchy desktop session"
note "Omarchy $(omarchy version)"
if git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  note "source commit $(git -C "$SCRIPT_DIR" rev-parse --short HEAD)"
fi

step "2/7" "Installing local audio and desktop dependencies"
omarchy pkg add git jq python pipewire-audio libsecret wl-clipboard wtype

step "3/7" "Installing the Antigravity protocol engine"
if ! pacman -Q antigravity >/dev/null 2>&1; then
  omarchy pkg aur add antigravity
fi
[[ -x "$LANGUAGE_SERVER" ]] \
  || fail "Antigravity installed without ${LANGUAGE_SERVER}"
check_antigravity_version \
  || fail "Antigravity ${MIN_ANTIGRAVITY_VERSION} or newer is required"
note "$(pacman -Q antigravity)"

step "4/7" "Linking and enabling Omarvoice"
omarchy plugin validate "$AGENT_PLUGIN"
omarchy plugin validate "$VOICE_PLUGIN"
"${SCRIPT_DIR}/install.sh" eipi10.agents
"${SCRIPT_DIR}/install.sh" qwen-asr
omarchy-shell shell rescanPlugins
omarchy bar put eipi10.agents --section right
omarchy bar put qwen-asr --section center
"$VOICE_CTL" set-shortcut "$shortcut" >/dev/null
hyprctl reload >/dev/null
hypr_errors="$(hyprctl configerrors)"
if [[ -n "$hypr_errors" ]]; then
  printf '%s\n' "$hypr_errors" >&2
  fail "Hyprland reported configuration errors"
fi
omarchy restart shell

step "5/7" "Preparing browser OAuth from the installed Antigravity engine"
"$AGENT_CTL" oauth-client-bootstrap

if "$skip_auth"; then
  note "browser authorization skipped by request"
  note "run this setup again without --skip-auth to finish"
  exit 0
fi

step "6/7" "Authorizing this machine in the browser"
auth_status="$("$AGENT_CTL" voice-auth-status 2>/dev/null || true)"
if "$force_auth" || ! json_ready "$auth_status"; then
  note "complete the Google authorization page opened in your browser"
  "$AGENT_CTL" oauth-start
else
  note "an active long-lived account already exists; keeping it"
fi
"$AGENT_CTL" voice-auth-sync

step "7/7" "Warming the service and running the final check"
"$VOICE_BRIDGE" warmup
health_check
note "hold ${shortcut} to record, then release to paste the transcript"
