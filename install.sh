#!/usr/bin/env bash
#
# install.sh - Safely symlink Omarchy plugins to ~/.config/omarchy/plugins
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS_SRC="${SCRIPT_DIR}/plugins"
TARGET_DIR="${HOME}/.config/omarchy/plugins"

mkdir -p "${TARGET_DIR}"

print_help() {
  echo "Usage: ./install.sh [all|<plugin-name>|list|uninstall <name|all>]"
  echo ""
  echo "Commands:"
  echo "  ./install.sh all            Symlink all plugins to ~/.config/omarchy/plugins/"
  echo "  ./install.sh <plugin-name>  Symlink a specific plugin (e.g. eipi10.agents)"
  echo "  ./install.sh list           List all available plugins in this repository"
  echo "  ./install.sh uninstall all  Remove symlinks created for these plugins"
  echo ""
}

list_plugins() {
  echo "Available plugins in repository:"
  for dir in "${PLUGINS_SRC}"/*; do
    if [[ -d "${dir}" ]]; then
      local name="$(basename "${dir}")"
      echo "  - ${name}"
    fi
  done
}

link_plugin() {
  local name="$1"
  local src="${PLUGINS_SRC}/${name}"
  local dst="${TARGET_DIR}/${name}"

  if [[ ! -d "${src}" ]]; then
    echo "[!] Error: Plugin '${name}' not found under ${PLUGINS_SRC}"
    return 1
  fi

  # If destination exists and is a regular dir (not symlink), back it up
  if [[ -e "${dst}" && ! -L "${dst}" ]]; then
    echo "[*] Backing up existing directory ${dst} to ${dst}.bak"
    mv "${dst}" "${dst}.bak"
  fi

  ln -sfn "${src}" "${dst}"
  echo "[+] Linked: ${name} -> ${dst}"
}

uninstall_plugin() {
  local name="$1"
  local dst="${TARGET_DIR}/${name}"
  if [[ -L "${dst}" ]]; then
    rm -f "${dst}"
    echo "[-] Removed symlink: ${dst}"
  fi
}

cmd="${1:-all}"

case "${cmd}" in
  list)
    list_plugins
    ;;
  all)
    echo "[*] Installing all Omarchy plugins..."
    for dir in "${PLUGINS_SRC}"/*; do
      if [[ -d "${dir}" ]]; then
        link_plugin "$(basename "${dir}")"
      fi
    done
    echo ""
    echo "[✓] All plugins linked successfully."
    echo "[*] Run 'omarchy-shell shell rescanPlugins' to reload your active shell."
    ;;
  uninstall)
    target_name="${2:-all}"
    if [[ "${target_name}" == "all" ]]; then
      echo "[*] Removing all plugin symlinks..."
      for dir in "${PLUGINS_SRC}"/*; do
        if [[ -d "${dir}" ]]; then
          uninstall_plugin "$(basename "${dir}")"
        fi
      done
    else
      uninstall_plugin "${target_name}"
    fi
    echo "[✓] Uninstall completed."
    ;;
  -h|--help|help)
    print_help
    ;;
  *)
    link_plugin "${cmd}"
    echo ""
    echo "[*] Run 'omarchy-shell shell rescanPlugins' to reload your active shell."
    ;;
esac
