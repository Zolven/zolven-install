#!/usr/bin/env bash
set -euo pipefail
trap '[ -t 1 ] && printf "\n"' EXIT
# cleanup.sh — Full cleanup of Zolven from this machine.
#
# Canonical public entrypoint:
#   curl -fsSL https://raw.githubusercontent.com/Zolven/zolven-install/main/cleanup.sh | bash
#
# This script is STANDALONE — it does not depend on any other file in the repo,
# so it keeps working even as it deletes the Zolven repo checkout itself.
#
# Defaults remain narrow: only Zolven-owned state is removed. OpenClaw and
# shared tooling (Node, pnpm, nvm, gh) are always preserved.

case "$(uname -s)" in
  Darwin) OS_KIND="macos" ;;
  Linux)  OS_KIND="linux" ;;
  *)      OS_KIND="other" ;;
esac

LOCAL_DEFAULT_REPO_DIR="$HOME/.local/opt/zolven"
LOCAL_DEFAULT_WATCH_DIR="$HOME/Documents/Zolven"
LOCAL_DEFAULT_DATA_DIR="$HOME/.local/share/zolven"

CLOUD_DEFAULT_REPO_DIR="/opt/zolven"
CLOUD_DEFAULT_DATA_DIR="/var/lib/zolven"
CLOUD_DEFAULT_CLI_LAUNCHER="/usr/local/bin/zolven"

default_local_cli_launcher() {
  case "$OS_KIND:$(id -u)" in
    linux:0) printf '%s\n' "/usr/local/bin/zolven" ;;
    *) printf '%s\n' "$HOME/.local/bin/zolven" ;;
  esac
}

INPUT_INSTALL_MODE="${ZOLVEN_INSTALL_MODE:-}"
INPUT_REPO_DIR="${ZOLVEN_REPO_DIR:-}"
INPUT_DATA_DIR="${ZOLVEN_DATA_DIR:-}"
INPUT_WATCH_DIR="${ZOLVEN_WATCH_DIR:-}"
INPUT_CLI_LAUNCHER_PATH="${ZOLVEN_CLI_LAUNCHER:-}"
INPUT_INSTALL_STATE_FILE="${ZOLVEN_INSTALL_STATE_FILE:-}"
INPUT_CLOUD_ENV_FILE="${ZOLVEN_CLOUD_ENV_FILE:-}"
INPUT_CLOUD_DECOMMISSION_URL="${ZOLVEN_CLOUD_DECOMMISSION_URL:-}"
INPUT_HIMALAYA_CONFIG_FILE="${ZOLVEN_HIMALAYA_CONFIG_FILE:-${HIMALAYA_CONFIG_FILE:-}}"
INPUT_OPENCLAW_PARENT_DIR="${OPENCLAW_WORKSPACE_PARENT_DIR:-${OPENCLAW_WORKSPACE_DIR:-}}"
INPUT_OPENCLAW_WORKSPACE_DIR="${ZOLVEN_OPENCLAW_WORKSPACE_DIR:-}"

INSTALL_MODE=""
REPO_DIR=""
DATA_DIR=""
WATCH_DIR=""
CLI_LAUNCHER_PATH=""
INSTALL_STATE_FILE=""
CLOUD_ENV_FILE=""
HIMALAYA_CONFIG_FILE=""
OPENCLAW_PARENT_DIR=""
OPENCLAW_WORKSPACE_DIR=""
SERVICE_MANAGER=""
SERVICE_UNITS_VALUE=""
LAUNCHD_LABELS_VALUE=""

CLOUD_API_BASE_URL=""
CLOUD_DECOMMISSION_URL=""
CLOUD_TENANT_SLUG=""
CLOUD_RUNTIME_ID=""
CLOUD_RUNTIME_SECRET=""

SYSTEMD_USER_UNIT_DIR="$HOME/.config/systemd/user"
SYSTEMD_SYSTEM_UNIT_DIR="/etc/systemd/system"

DEFAULT_DASHBOARD_PORT="${ZOLVEN_DASHBOARD_PORT:-${ZOLVEN_PORT:-3100}}"
DEFAULT_API_PORT="${ZOLVEN_API_PORT:-3101}"

if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  SUDO=""
fi

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  TTY_RESET=$'\033[0m'
  TTY_BOLD=$'\033[1m'
  TTY_DIM=$'\033[2m'
  TTY_BLUE=$'\033[38;5;75m'
  TTY_GREEN=$'\033[38;5;114m'
  TTY_YELLOW=$'\033[38;5;179m'
  TTY_RED=$'\033[31m'
else
  TTY_RESET=""
  TTY_BOLD=""
  TTY_DIM=""
  TTY_BLUE=""
  TTY_GREEN=""
  TTY_YELLOW=""
  TTY_RED=""
fi

CLEANUP_RULE="-----------------"

fmt_path() {
  local p="${1:-}"
  if [ -z "$p" ]; then printf -- '—'; return; fi
  if [ -n "${HOME:-}" ] && [ "${p#"$HOME"}" != "$p" ]; then
    printf '~%s' "${p#"$HOME"}"
  else
    printf '%s' "$p"
  fi
}

fmt_presence() {
  local p="$1" kind="${2:-path}"
  case "$kind" in
    dir)   if [ -d "$p" ]; then printf '[present]'; else printf '[missing]'; fi ;;
    file)  if [ -f "$p" ]; then printf '[present]'; else printf '[missing]'; fi ;;
    git)   if [ -d "$p/.git" ]; then printf '[present]'; else printf '[missing]'; fi ;;
    any)   if [ -e "$p" ] || [ -L "$p" ]; then printf '[present]'; else printf '[missing]'; fi ;;
  esac
}

tty_header() {
  printf '\n%b->%b %b%s%b\n\n' "$TTY_BLUE" "$TTY_RESET" "$TTY_BOLD" "$1" "$TTY_RESET"
}

tty_rule() {
  printf '%s\n' "$CLEANUP_RULE"
}

tty_kv() {
  # tty_kv LABEL VALUE [HINT]
  local label="$1" value="${2:-—}" hint="${3:-}"
  if [ -n "$hint" ]; then
    printf '  %-20s %s  %b%s%b\n' "$label" "$value" "$TTY_DIM" "$hint" "$TTY_RESET"
  else
    printf '  %-20s %s\n' "$label" "$value"
  fi
}

tty_note() {
  printf '  %b%s%b\n' "$TTY_DIM" "$*" "$TTY_RESET"
}

DRY_RUN=0
YES=0
KEEP_REPO=0
KEEP_DATA_DIR=0
KEEP_WATCH_DIR=0
KEEP_OPENCLAW_WORKSPACE=0
KEEP_CLOUD_REGISTRATION=0
PURGE_INTELLIGENCE_CLI=0

usage() {
  cat <<EOF
Usage: bash cleanup.sh [options]

Remove Zolven from this machine, thoroughly enough for a clean reinstall.

The script understands both local and cloud installs. Cloud cleanup adds a
best-effort runtime decommission step before local files are removed unless you
pass --keep-cloud-registration.

By default the script removes only Zolven-owned state:
  • Zolven launchd plist (macOS) or systemd units (Linux)
  • running Zolven services
  • CLI launcher
  • Zolven repo checkout
  • repo .env.local (secrets)
  • runtime data dir
  • watch dir
  • Zolven Intelligence workspace
  • Zolven-managed Himalaya mail accounts (~/.config/himalaya/config.toml)

OpenClaw, unrelated OpenClaw workspaces, and shared Node/pnpm/nvm/gh tooling are
always preserved. The Zolven Intelligence CLI is preserved unless explicitly
selected for removal.

Options:
  --dry-run                      Show what would be removed, do nothing.
  -y, --yes                      Skip confirmation prompts.
  --keep-repo                    Don't remove the Zolven repo checkout.
  --keep-data-dir                Don't remove the Zolven runtime data dir.
  --keep-watch-dir               Don't remove the watch directory.
  --keep-intelligence-workspace  Don't remove the Zolven Intelligence workspace.
  --keep-cloud-registration      Cloud mode only: skip best-effort runtime decommission.
  --purge-intelligence-cli       Also remove the Zolven Intelligence CLI npm package.
  -h, --help                     Show this help.

Environment:
  ZOLVEN_INSTALL_STATE_FILE      Explicit install state file path
  ZOLVEN_REPO_DIR                Repo location override
  ZOLVEN_DATA_DIR                Runtime data dir override
  ZOLVEN_WATCH_DIR               Watch dir override
  ZOLVEN_CLI_LAUNCHER            CLI launcher override
  ZOLVEN_OPENCLAW_WORKSPACE_DIR  Product-owned OpenClaw workspace override
  OPENCLAW_WORKSPACE_PARENT_DIR  Upstream OpenClaw workspace parent override
  ZOLVEN_CLOUD_ENV_FILE          Explicit cloud bootstrap env path
  ZOLVEN_CLOUD_DECOMMISSION_URL  Explicit cloud decommission endpoint
  ZOLVEN_HIMALAYA_CONFIG_FILE    Himalaya config path override
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)                 DRY_RUN=1 ;;
    -y|--yes)                  YES=1 ;;
    --keep-repo)               KEEP_REPO=1 ;;
    --keep-data-dir)           KEEP_DATA_DIR=1 ;;
    --keep-watch-dir)          KEEP_WATCH_DIR=1 ;;
    --keep-intelligence-workspace|--keep-openclaw-workspace) KEEP_OPENCLAW_WORKSPACE=1 ;;
    --keep-cloud-registration) KEEP_CLOUD_REGISTRATION=1 ;;
    --purge-intelligence-cli)  PURGE_INTELLIGENCE_CLI=1 ;;
    -h|--help)                 usage; exit 0 ;;
    *)
      printf '%sERROR:%s Unknown argument: %s\n' "$TTY_RED" "$TTY_RESET" "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

say()  { printf '%b%s%b\n' "$TTY_DIM" "$*" "$TTY_RESET"; }
ok()   { printf '%bOK%b  %s\n' "$TTY_GREEN" "$TTY_RESET" "$*"; }
warn() { printf '%bWARN:%b %s\n' "$TTY_YELLOW" "$TTY_RESET" "$*" >&2; }
plan() { printf '%bplan%b  %s\n' "$TTY_DIM" "$TTY_RESET" "$*"; }
fail() { printf '%bERROR:%b %s\n' "$TTY_RED" "$TTY_RESET" "$*" >&2; exit 1; }

path_is_zolven_owned() {
  local target="${1:-}"

  case "$target" in
    /*) ;;
    *) return 1 ;;
  esac
  case "/$target/" in
    */../*|*/./*) return 1 ;;
  esac
  case "$target" in
    */zolven/*|*/Zolven/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

path_is_zolven_removal_target() {
  local target="${1:-}"

  case "$target" in
    /*) ;;
    *) return 1 ;;
  esac
  case "/$target/" in
    */../*|*/./*) return 1 ;;
  esac
  case "$target" in
    */zolven|*/Zolven|*/zolven/.env.local|*/Zolven/.env.local)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

filter_service_units() {
  local units="$1" unit filtered=""
  local -a unit_list=()
  read -r -a unit_list <<<"$units"
  for unit in "${unit_list[@]}"; do
    case "$unit" in
      *[!A-Za-z0-9_.@-]*)
        warn "Ignoring invalid Zolven service unit from install state: $unit"
        ;;
      zolven-*.service|zolven-*.timer)
        filtered="${filtered:+$filtered }$unit"
        ;;
      *)
        warn "Ignoring non-Zolven service unit from install state: $unit"
        ;;
    esac
  done
  printf '%s\n' "$filtered"
}

filter_launchd_labels() {
  local labels="$1" label filtered=""
  local -a label_list=()
  read -r -a label_list <<<"$labels"
  for label in "${label_list[@]}"; do
    case "$label" in
      *[!A-Za-z0-9_.-]*)
        warn "Ignoring invalid Zolven launchd label from install state: $label"
        ;;
      ai.zolven.*)
        filtered="${filtered:+$filtered }$label"
        ;;
      *)
        warn "Ignoring non-Zolven launchd label from install state: $label"
        ;;
    esac
  done
  printf '%s\n' "$filtered"
}

repo_origin_is_zolven() {
  local origin_url
  origin_url="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
  case "$origin_url" in
    https://github.com/Zolven/zolven|https://github.com/Zolven/zolven.git|git@github.com:Zolven/zolven.git|ssh://git@github.com/Zolven/zolven.git)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

run_with_sudo() {
  if [ -n "$SUDO" ]; then
    "$SUDO" "$@"
  else
    "$@"
  fi
}

load_env_file() {
  local file="$1"
  [ -f "$file" ] || return 1
  if ! path_is_zolven_owned "$file"; then
    warn "Refusing to load environment file outside a Zolven-owned path: $file"
    return 1
  fi
  # shellcheck disable=SC1090
  . "$file"
}

discover_install_state_file() {
  if [ -n "$INPUT_INSTALL_STATE_FILE" ]; then
    printf '%s\n' "$INPUT_INSTALL_STATE_FILE"
    return
  fi

  if [ -n "$INPUT_DATA_DIR" ]; then
    printf '%s\n' "$INPUT_DATA_DIR/install/install-state.env"
    return
  fi

  if [ -f "$LOCAL_DEFAULT_DATA_DIR/install/install-state.env" ]; then
    printf '%s\n' "$LOCAL_DEFAULT_DATA_DIR/install/install-state.env"
    return
  fi

  if [ -f "$CLOUD_DEFAULT_DATA_DIR/install/install-state.env" ]; then
    printf '%s\n' "$CLOUD_DEFAULT_DATA_DIR/install/install-state.env"
    return
  fi

  printf '%s\n' "$LOCAL_DEFAULT_DATA_DIR/install/install-state.env"
}

default_install_mode() {
  if [ -n "$INPUT_INSTALL_MODE" ]; then
    printf '%s\n' "$INPUT_INSTALL_MODE"
    return
  fi

  if [ -f "$CLOUD_DEFAULT_DATA_DIR/install/install-state.env" ] && [ ! -f "$LOCAL_DEFAULT_DATA_DIR/install/install-state.env" ]; then
    printf '%s\n' "cloud"
    return
  fi

  printf '%s\n' "local"
}

resolve_defaults() {
  INSTALL_STATE_FILE="$(discover_install_state_file)"
  if [ -f "$INSTALL_STATE_FILE" ]; then
    load_env_file "$INSTALL_STATE_FILE" || true
  fi

  INSTALL_MODE="${INPUT_INSTALL_MODE:-${ZOLVEN_INSTALL_MODE:-$(default_install_mode)}}"
  case "$INSTALL_MODE" in
    local|cloud) ;;
    *) warn "Unknown install mode '$INSTALL_MODE' in overrides/state; falling back to local."; INSTALL_MODE="local" ;;
  esac

  if [ "$INSTALL_MODE" = "cloud" ]; then
    REPO_DIR="${INPUT_REPO_DIR:-${ZOLVEN_REPO_DIR:-$CLOUD_DEFAULT_REPO_DIR}}"
    DATA_DIR="${INPUT_DATA_DIR:-${ZOLVEN_DATA_DIR:-$CLOUD_DEFAULT_DATA_DIR}}"
    CLI_LAUNCHER_PATH="${INPUT_CLI_LAUNCHER_PATH:-${ZOLVEN_CLI_LAUNCHER:-$CLOUD_DEFAULT_CLI_LAUNCHER}}"
    SERVICE_MANAGER="${ZOLVEN_SERVICE_MANAGER:-systemd-system}"
    SERVICE_UNITS_VALUE="${ZOLVEN_SERVICE_UNITS:-zolven-api.service zolven-dashboard.service zolven-worker.service zolven-worker.timer zolven-proxy.service zolven-tunnel.service}"
  else
    REPO_DIR="${INPUT_REPO_DIR:-${ZOLVEN_REPO_DIR:-$LOCAL_DEFAULT_REPO_DIR}}"
    DATA_DIR="${INPUT_DATA_DIR:-${ZOLVEN_DATA_DIR:-$LOCAL_DEFAULT_DATA_DIR}}"
    CLI_LAUNCHER_PATH="${INPUT_CLI_LAUNCHER_PATH:-${ZOLVEN_CLI_LAUNCHER:-$(default_local_cli_launcher)}}"
    SERVICE_MANAGER="${ZOLVEN_SERVICE_MANAGER:-}"
    if [ -z "$SERVICE_MANAGER" ]; then
      if [ "$OS_KIND" = "macos" ]; then
        SERVICE_MANAGER="launchd"
      elif [ "$OS_KIND" = "linux" ]; then
        SERVICE_MANAGER="systemd-user"
      else
        SERVICE_MANAGER="manual"
      fi
    fi
    SERVICE_UNITS_VALUE="${ZOLVEN_SERVICE_UNITS:-zolven-api.service zolven-dashboard.service zolven-worker.service zolven-worker.timer}"
  fi

  WATCH_DIR="${INPUT_WATCH_DIR:-${ZOLVEN_WATCH_DIR:-$LOCAL_DEFAULT_WATCH_DIR}}"
  LAUNCHD_LABELS_VALUE="${ZOLVEN_LAUNCHD_LABELS:-ai.zolven.dashboard}"
  CLOUD_ENV_FILE="${INPUT_CLOUD_ENV_FILE:-${ZOLVEN_CLOUD_ENV_FILE:-$DATA_DIR/config/cloud-bootstrap.env}}"

  if [ -f "$CLOUD_ENV_FILE" ]; then
    load_env_file "$CLOUD_ENV_FILE" || true
  fi

  if [ "$INSTALL_MODE" = "cloud" ]; then
    OPENCLAW_PARENT_DIR="${INPUT_OPENCLAW_PARENT_DIR:-${OPENCLAW_WORKSPACE_PARENT_DIR:-$DATA_DIR/openclaw/workspace}}"
  else
    OPENCLAW_PARENT_DIR="${INPUT_OPENCLAW_PARENT_DIR:-${OPENCLAW_WORKSPACE_PARENT_DIR:-$HOME/.openclaw/workspace}}"
  fi
  OPENCLAW_WORKSPACE_DIR="${INPUT_OPENCLAW_WORKSPACE_DIR:-${ZOLVEN_OPENCLAW_WORKSPACE_DIR:-$OPENCLAW_PARENT_DIR/zolven}}"
  CLOUD_API_BASE_URL="${ZOLVEN_CLOUD_API_BASE_URL:-$CLOUD_API_BASE_URL}"
  CLOUD_DECOMMISSION_URL="${INPUT_CLOUD_DECOMMISSION_URL:-${ZOLVEN_CLOUD_DECOMMISSION_URL:-$CLOUD_DECOMMISSION_URL}}"
  CLOUD_TENANT_SLUG="${ZOLVEN_TENANT_SLUG:-$CLOUD_TENANT_SLUG}"
  CLOUD_RUNTIME_ID="${ZOLVEN_RUNTIME_ID:-$CLOUD_RUNTIME_ID}"
  CLOUD_RUNTIME_SECRET="${ZOLVEN_RUNTIME_SECRET:-$CLOUD_RUNTIME_SECRET}"

  SERVICE_UNITS_VALUE="$(filter_service_units "$SERVICE_UNITS_VALUE")"
  LAUNCHD_LABELS_VALUE="$(filter_launchd_labels "$LAUNCHD_LABELS_VALUE")"

  # Zolven writes marker-fenced account blocks into the shared Himalaya config.
  # Use the captured INPUT_* value because env files sourced above may have
  # changed the product or upstream config variables in between.
  HIMALAYA_CONFIG_FILE="$INPUT_HIMALAYA_CONFIG_FILE"
  if [ -z "$HIMALAYA_CONFIG_FILE" ]; then
    case "$INSTALL_MODE" in
      cloud) HIMALAYA_CONFIG_FILE="$DATA_DIR/config/himalaya/config.toml" ;;
      *)     HIMALAYA_CONFIG_FILE="$HOME/.config/himalaya/config.toml" ;;
    esac
  fi
}

confirm() {
  local msg="$1"
  local default_yes="${2:-0}"
  if [ "$YES" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  if ! [ -t 0 ] || ! [ -r /dev/tty ]; then
    warn "Non-interactive shell without -y; aborting to stay safe."
    exit 1
  fi
  local hint='[y/N]'
  [ "$default_yes" = "1" ] && hint='[Y/n]'
  printf '%s %s ' "$msg" "$hint" > /dev/tty
  local reply=""
  read -r reply < /dev/tty || reply=""
  if [ "$default_yes" = "1" ]; then
    [[ -z "$reply" || "$reply" =~ ^[Yy]$ ]]
  else
    [[ "$reply" =~ ^[Yy]$ ]]
  fi
}

menu_can_prompt() {
  [ "$YES" -eq 1 ] && return 1
  [ "$DRY_RUN" -eq 1 ] && return 1
  # If CLI flags already flipped any toggle, treat CLI as the authoritative UI.
  if [ "$KEEP_REPO" -eq 1 ] \
     || [ "$KEEP_DATA_DIR" -eq 1 ] \
     || [ "$KEEP_WATCH_DIR" -eq 1 ] \
     || [ "$KEEP_OPENCLAW_WORKSPACE" -eq 1 ] \
     || [ "$KEEP_CLOUD_REGISTRATION" -eq 1 ] \
     || [ "$PURGE_INTELLIGENCE_CLI" -eq 1 ]; then
    return 1
  fi
  [ -t 0 ] && [ -r /dev/tty ] && return 0
  return 1
}

menu_mark() {
  # menu_mark FLAG_VALUE → prints "x" or " " in TTY box
  if [ "${1:-0}" = "1" ]; then
    printf '%bx%b' "$TTY_GREEN" "$TTY_RESET"
  else
    printf ' '
  fi
}

menu_row() {
  # menu_row NUMBER FLAG_VALUE NAME DESCRIPTION
  local num="$1" val="$2" name="$3" desc="$4"
  printf '  [%s] %d) %-32s %b%s%b\n' "$(menu_mark "$val")" "$num" "$name" "$TTY_DIM" "$desc" "$TTY_RESET"
}

menu_apply_preset() {
  # Reset then apply preset. Called with preset name.
  DRY_RUN=0
  KEEP_REPO=0
  KEEP_DATA_DIR=0
  KEEP_WATCH_DIR=0
  KEEP_OPENCLAW_WORKSPACE=0
  KEEP_CLOUD_REGISTRATION=0
  PURGE_INTELLIGENCE_CLI=0

  case "$1" in
    default) ;;
    keep_data)
      KEEP_DATA_DIR=1
      KEEP_WATCH_DIR=1
      KEEP_OPENCLAW_WORKSPACE=1
      ;;
    keep_repo)
      KEEP_REPO=1
      ;;
    product_purge)
      PURGE_INTELLIGENCE_CLI=1
      ;;
    dry_run)
      DRY_RUN=1
      ;;
  esac
}

menu_customize() {
  local reply
  while true; do
    tty_header "Customize flags"
    tty_note "press a number to toggle; empty line to continue; 'q' to go back"
    printf '\n'
    menu_row 1 "$DRY_RUN"                   "dry-run"                       "Preview only — nothing is changed."
    menu_row 2 "$KEEP_REPO"                 "keep-repo"                     "Don't remove the Zolven repo checkout."
    menu_row 3 "$KEEP_DATA_DIR"             "keep-data-dir"                 "Don't remove the runtime data dir (SQLite, secrets, chat)."
    menu_row 4 "$KEEP_WATCH_DIR"            "keep-watch-dir"                "Don't remove the watch directory."
    menu_row 5 "$KEEP_OPENCLAW_WORKSPACE"   "keep-intelligence-workspace"   "Don't remove the Zolven Intelligence workspace."
    menu_row 6 "$KEEP_CLOUD_REGISTRATION"   "keep-cloud-registration"       "Cloud only: skip runtime decommission."
    menu_row 7 "$PURGE_INTELLIGENCE_CLI"    "purge-intelligence-cli"        "Also remove the Zolven Intelligence CLI npm package."
    printf '\n'
    printf '> ' > /dev/tty
    read -r reply < /dev/tty || reply=""
    case "$reply" in
      "") return 0 ;;
      q|Q) return 1 ;;
      1) DRY_RUN=$((1 - DRY_RUN)) ;;
      2) KEEP_REPO=$((1 - KEEP_REPO)) ;;
      3) KEEP_DATA_DIR=$((1 - KEEP_DATA_DIR)) ;;
      4) KEEP_WATCH_DIR=$((1 - KEEP_WATCH_DIR)) ;;
      5) KEEP_OPENCLAW_WORKSPACE=$((1 - KEEP_OPENCLAW_WORKSPACE)) ;;
      6) KEEP_CLOUD_REGISTRATION=$((1 - KEEP_CLOUD_REGISTRATION)) ;;
      7) PURGE_INTELLIGENCE_CLI=$((1 - PURGE_INTELLIGENCE_CLI)) ;;
      *) tty_note "Unknown option: $reply" ;;
    esac
  done
}

interactive_menu() {
  menu_can_prompt || return 0

  while true; do
    tty_header "Choose what to clean"
    printf '  1) %-18s %b%s%b\n' "Default cleanup"   "$TTY_DIM" "Remove Zolven state; keep shared tooling. (recommended)" "$TTY_RESET"
    printf '  2) %-18s %b%s%b\n' "Keep user data"    "$TTY_DIM" "Preserve data dir, watch dir, and Zolven workspace." "$TTY_RESET"
    printf '  3) %-18s %b%s%b\n' "Keep the repo"     "$TTY_DIM" "Preserve the Zolven repo checkout." "$TTY_RESET"
    printf '  4) %-18s %b%s%b\n' "Product purge"     "$TTY_DIM" "Default cleanup + Zolven Intelligence CLI." "$TTY_RESET"
    printf '  5) %-18s %b%s%b\n' "Dry run"           "$TTY_DIM" "Preview only — no changes." "$TTY_RESET"
    printf '  6) %-18s %b%s%b\n' "Custom..."         "$TTY_DIM" "Toggle individual flags one by one." "$TTY_RESET"
    printf '  0) %-18s %b%s%b\n' "Abort"             "$TTY_DIM" "Quit without changes." "$TTY_RESET"
    printf '\nSelect [1]: ' > /dev/tty
    local reply=""
    read -r reply < /dev/tty || reply=""
    case "${reply:-1}" in
      1) menu_apply_preset default;     return 0 ;;
      2) menu_apply_preset keep_data;   return 0 ;;
      3) menu_apply_preset keep_repo;   return 0 ;;
      4) menu_apply_preset product_purge; return 0 ;;
      5) menu_apply_preset dry_run;     return 0 ;;
      6) menu_customize && return 0 ;;
      0|q|Q) say "Aborted."; exit 0 ;;
      *) tty_note "Unknown option: $reply"; printf '\n' ;;
    esac
  done
}

run_cmd() {
  local label="$1"
  shift
  if [ "$DRY_RUN" -eq 1 ]; then
    plan "$label"
    return 0
  fi
  "$@"
}

path_needs_sudo() {
  local target="$1"
  if [ -e "$target" ] || [ -L "$target" ]; then
    [ -w "$target" ] && return 1
    return 0
  fi

  [ -w "$(dirname "$target")" ] && return 1
  return 0
}

rm_path() {
  local target="$1"
  local label="${2:-$target}"
  if [ -z "$target" ] || [ "$target" = "/" ] || [ "$target" = "$HOME" ]; then
    warn "Refusing to remove dangerous path: '$target' ($label)"
    return 0
  fi
  if ! path_is_zolven_removal_target "$target"; then
    warn "Refusing to remove path outside Zolven ownership: $target ($label)"
    return 0
  fi
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    plan "rm -rf $target ($label)"
    return 0
  fi
  if path_needs_sudo "$target"; then
    run_with_sudo rm -rf -- "$target"
  else
    rm -rf -- "$target"
  fi
  ok "Removed $label ($target)"
}

decommission_url() {
  if [ -n "$CLOUD_DECOMMISSION_URL" ]; then
    printf '%s\n' "$CLOUD_DECOMMISSION_URL"
    return
  fi

  if [ -n "$CLOUD_API_BASE_URL" ] && [ -n "$CLOUD_RUNTIME_ID" ]; then
    printf '%s\n' "${CLOUD_API_BASE_URL%/}/v1/runtimes/$CLOUD_RUNTIME_ID/decommission"
  fi
}

summarize() {
  tty_header "Zolven cleanup plan"
  tty_kv "Mode"            "$INSTALL_MODE"
  tty_kv "Install state"   "$(fmt_path "$INSTALL_STATE_FILE")"   "$(fmt_presence "$INSTALL_STATE_FILE" file)"
  tty_kv "Repo"            "$(fmt_path "$REPO_DIR")"             "$(fmt_presence "$REPO_DIR" git)"
  tty_kv "Data dir"        "$(fmt_path "$DATA_DIR")"             "$(fmt_presence "$DATA_DIR" dir)"
  tty_kv "Watch dir"       "$(fmt_path "$WATCH_DIR")"            "$(fmt_presence "$WATCH_DIR" dir)"
  tty_kv "CLI launcher"    "$(fmt_path "$CLI_LAUNCHER_PATH")"    "$(fmt_presence "$CLI_LAUNCHER_PATH" any)"
  tty_kv "Service manager" "$SERVICE_MANAGER"
  tty_kv "Service units"   "${SERVICE_UNITS_VALUE:-<none>}"
  tty_kv "Intelligence ws" "$(fmt_path "$OPENCLAW_WORKSPACE_DIR")" "$(fmt_presence "$OPENCLAW_WORKSPACE_DIR" dir)"
  tty_kv "Himalaya config" "$(fmt_path "$HIMALAYA_CONFIG_FILE")" "$(fmt_presence "$HIMALAYA_CONFIG_FILE" file)"
  if [ "$INSTALL_MODE" = "cloud" ]; then
    tty_kv "Cloud env"       "$(fmt_path "$CLOUD_ENV_FILE")"       "$(fmt_presence "$CLOUD_ENV_FILE" file)"
    tty_kv "Tenant slug"     "${CLOUD_TENANT_SLUG:-<unknown>}"
    tty_kv "Runtime id"      "${CLOUD_RUNTIME_ID:-<unknown>}"
    tty_kv "Decommission URL" "$(decommission_url)"
  fi

  printf '\n'
  tty_note "flags: dry_run=$DRY_RUN  yes=$YES"
  tty_note "       keep_repo=$KEEP_REPO  keep_data=$KEEP_DATA_DIR  keep_watch=$KEEP_WATCH_DIR  keep_intel=$KEEP_OPENCLAW_WORKSPACE  keep_cloud=$KEEP_CLOUD_REGISTRATION"
  tty_note "       purge_intel=$PURGE_INTELLIGENCE_CLI"
  printf '\n'
}

stage_cloud_decommission() {
  local url payload
  [ "$INSTALL_MODE" = "cloud" ] || return 0
  [ "$KEEP_CLOUD_REGISTRATION" -eq 0 ] || { say "Keeping cloud runtime registration (--keep-cloud-registration)"; return 0; }

  url="$(decommission_url)"
  if [ -z "$url" ]; then
    warn "Cloud runtime registration cleanup skipped: no decommission endpoint configured."
    return 0
  fi
  if [ -z "$CLOUD_RUNTIME_ID" ] || [ -z "$CLOUD_RUNTIME_SECRET" ]; then
    warn "Cloud runtime registration cleanup skipped: runtime_id/runtime_secret not available."
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl not found; skipping cloud runtime decommission."
    return 0
  fi

  payload=$(printf '{"runtime_id":"%s","tenant_slug":"%s","requested_at":"%s"}' \
    "$CLOUD_RUNTIME_ID" "$CLOUD_TENANT_SLUG" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")

  if [ "$DRY_RUN" -eq 1 ]; then
    plan "POST $url (best-effort cloud runtime decommission for $CLOUD_RUNTIME_ID)"
    return 0
  fi

  say "Attempting cloud runtime decommission for $CLOUD_RUNTIME_ID"
  if curl -fsSL \
    -H 'Content-Type: application/json' \
    -H "X-Zolven-Runtime-Id: $CLOUD_RUNTIME_ID" \
    -H "X-Zolven-Runtime-Secret: $CLOUD_RUNTIME_SECRET" \
    -X POST \
    --data "$payload" \
    "$url" >/dev/null 2>&1; then
    ok "Cloud runtime registration decommissioned"
  else
    warn "Cloud runtime decommission failed (ignored). Host cleanup will continue."
  fi
}

stage_stop_via_cli() {
  local bin=""
  if [ -x "$CLI_LAUNCHER_PATH" ]; then
    bin="$CLI_LAUNCHER_PATH"
  elif [ -x "$REPO_DIR/bin/zolven" ]; then
    bin="$REPO_DIR/bin/zolven"
  fi
  if [ -z "$bin" ]; then
    return 0
  fi
  if ! path_is_zolven_removal_target "$bin"; then
    warn "Refusing to execute CLI outside a Zolven-owned path: $bin"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    plan "$bin stop --force  (graceful shutdown via Zolven CLI)"
    return 0
  fi
  say "Stopping Zolven via $bin stop --force"
  "$bin" stop --force >/dev/null 2>&1 || true
}

stage_stop_launchd() {
  local label domain plist_path
  local -a labels=()
  [ "$SERVICE_MANAGER" = "launchd" ] || return 0
  domain="gui/$(id -u)"

  read -r -a labels <<<"$LAUNCHD_LABELS_VALUE"
  for label in "${labels[@]}"; do
    plist_path="$HOME/Library/LaunchAgents/$label.plist"
    [ -f "$plist_path" ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then
      plan "launchctl bootout $domain $plist_path"
      plan "rm $plist_path"
      continue
    fi
    say "Unloading launchd agent $label"
    launchctl bootout "$domain" "$plist_path" >/dev/null 2>&1 || true
    rm -f "$plist_path"
    ok "Removed launchd plist ($plist_path)"
  done
}

stage_stop_systemd() {
  local unit any unit_dir
  local -a units=()
  case "$SERVICE_MANAGER" in
    systemd-user) unit_dir="$SYSTEMD_USER_UNIT_DIR" ;;
    systemd-system) unit_dir="$SYSTEMD_SYSTEM_UNIT_DIR" ;;
    *) return 0 ;;
  esac

  read -r -a units <<<"$SERVICE_UNITS_VALUE"
  [ "${#units[@]}" -gt 0 ] || return 0

  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  any=0
  for unit in "${units[@]}"; do
    if [ -f "$unit_dir/$unit" ]; then
      any=1
      break
    fi
  done
  if [ "$any" -eq 0 ] && [ "$SERVICE_MANAGER" = "systemd-user" ]; then
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$SERVICE_MANAGER" = "systemd-system" ]; then
      plan "systemctl disable --now $SERVICE_UNITS_VALUE"
    else
      plan "systemctl --user disable --now $SERVICE_UNITS_VALUE"
    fi
    for unit in "${units[@]}"; do
      [ -f "$unit_dir/$unit" ] && plan "rm $unit_dir/$unit"
    done
    if [ "$SERVICE_MANAGER" = "systemd-system" ]; then
      plan "systemctl daemon-reload"
    else
      plan "systemctl --user daemon-reload"
    fi
    return 0
  fi

  say "Stopping + disabling Zolven systemd units"
  if [ "$SERVICE_MANAGER" = "systemd-system" ]; then
    run_with_sudo systemctl disable --now "${units[@]}" >/dev/null 2>&1 || true
  else
    systemctl --user disable --now "${units[@]}" >/dev/null 2>&1 || true
  fi

  for unit in "${units[@]}"; do
    if [ -f "$unit_dir/$unit" ]; then
      if [ "$SERVICE_MANAGER" = "systemd-system" ]; then
        run_with_sudo rm -f "$unit_dir/$unit"
      else
        rm -f "$unit_dir/$unit"
      fi
      ok "Removed $unit_dir/$unit"
    fi
  done

  if [ "$SERVICE_MANAGER" = "systemd-system" ]; then
    run_with_sudo systemctl daemon-reload >/dev/null 2>&1 || true
  else
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
}

process_is_zolven_owned() {
  local pid="$1" process_path process_name process_paths="" repo_path

  case "$pid" in
    ""|*[!0-9]*) return 1 ;;
  esac
  path_is_zolven_removal_target "$REPO_DIR" || return 1
  repo_path="$(cd "$REPO_DIR" 2>/dev/null && pwd -P)" || return 1

  if [ "$SERVICE_MANAGER" = "systemd-system" ]; then
    process_paths="$(run_with_sudo lsof -a -p "$pid" -d cwd,txt -Fn 2>/dev/null || true)"
  else
    process_paths="$(lsof -a -p "$pid" -d cwd,txt -Fn 2>/dev/null || true)"
  fi

  while IFS= read -r process_path; do
    process_path="${process_path#n}"
    case "$process_path" in
      "$repo_path"|"$repo_path"/*|"$CLI_LAUNCHER_PATH")
        return 0
        ;;
    esac
  done <<<"$process_paths"

  process_name="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
  process_name="${process_name##*/}"
  case "$process_name" in
    zolven|zolven-*) return 0 ;;
    *) return 1 ;;
  esac
}

stage_free_ports() {
  local port pids="" pid owned_pids=""
  command -v lsof >/dev/null 2>&1 || return 0

  for port in "$DEFAULT_DASHBOARD_PORT" "$DEFAULT_API_PORT"; do
    owned_pids=""
    if [ "$SERVICE_MANAGER" = "systemd-system" ]; then
      pids="$(run_with_sudo lsof -ti "tcp:$port" 2>/dev/null || true)"
    else
      pids="$(lsof -ti "tcp:$port" -a -u "$(id -un)" 2>/dev/null || true)"
    fi

    for pid in $pids; do
      if process_is_zolven_owned "$pid"; then
        owned_pids="${owned_pids:+$owned_pids }$pid"
      else
        warn "Leaving unrelated process $pid listening on :$port"
      fi
    done
    [ -n "$owned_pids" ] || continue

    if [ "$DRY_RUN" -eq 1 ]; then
      plan "kill $owned_pids  (Zolven process still listening on :$port)"
      continue
    fi

    say "Killing leftover Zolven process on :$port (pids: $owned_pids)"
    for pid in $owned_pids; do
      if ! process_is_zolven_owned "$pid"; then
        warn "Leaving process $pid because Zolven ownership changed before shutdown"
      elif [ "$SERVICE_MANAGER" = "systemd-system" ]; then
        run_with_sudo kill "$pid" 2>/dev/null || true
      else
        kill "$pid" 2>/dev/null || true
      fi
    done

    sleep 2
    for pid in $owned_pids; do
      if kill -0 "$pid" 2>/dev/null && process_is_zolven_owned "$pid"; then
        if [ "$SERVICE_MANAGER" = "systemd-system" ]; then
          run_with_sudo kill -9 "$pid" 2>/dev/null || true
        else
          kill -9 "$pid" 2>/dev/null || true
        fi
      fi
    done
  done
}

stage_remove_cli_launcher() {
  rm_path "$CLI_LAUNCHER_PATH" "CLI launcher"
}

stage_remove_env_local() {
  local env_file="$REPO_DIR/.env.local"
  rm_path "$env_file" "repo .env.local"
}

stage_remove_data_dir() {
  [ "$KEEP_DATA_DIR" -eq 0 ] || { say "Keeping data dir (--keep-data-dir)"; return 0; }
  rm_path "$DATA_DIR" "data dir"
}

stage_remove_watch_dir() {
  [ "$KEEP_WATCH_DIR" -eq 0 ] || { say "Keeping watch dir (--keep-watch-dir)"; return 0; }
  rm_path "$WATCH_DIR" "watch dir"
}

stage_remove_openclaw_workspace() {
  [ "$KEEP_OPENCLAW_WORKSPACE" -eq 0 ] || { say "Keeping Zolven Intelligence workspace (--keep-intelligence-workspace)"; return 0; }

  case "$OPENCLAW_WORKSPACE_DIR" in
    */zolven) ;;
    *)
      warn "Intelligence workspace path does not end in /zolven — skipping to avoid removing an unrelated workspace: $OPENCLAW_WORKSPACE_DIR"
      return 0
      ;;
  esac
  rm_path "$OPENCLAW_WORKSPACE_DIR" "Zolven Intelligence workspace"
}

stage_remove_himalaya_accounts() {
  # With --keep-intelligence-workspace the product workspace remains usable, so
  # leave its marker-fenced mail accounts in place as well.
  [ "${KEEP_OPENCLAW_WORKSPACE:-0}" -eq 1 ] && return 0

  # Zolven writes each mail account into the shared Himalaya config as a
  # marker-fenced block (see scripts/mail-setup.sh). Strip only those product
  # blocks and leave every account or setting a user added by hand untouched.
  local config_file
  config_file="${ZOLVEN_HIMALAYA_CONFIG_FILE:-${HIMALAYA_CONFIG_FILE:-}}"
  if [ -z "$config_file" ]; then
    case "${INSTALL_MODE:-local}" in
      cloud) config_file="${DATA_DIR:-}/config/himalaya/config.toml" ;;
      *)     config_file="$HOME/.config/himalaya/config.toml" ;;
    esac
  fi

  [ -f "$config_file" ] || return 0
  grep -q '^# >>> Zolven mail account: ' "$config_file" 2>/dev/null || return 0

  if [ "$DRY_RUN" -eq 1 ]; then
    plan "strip Zolven-managed mail account blocks from $config_file"
    plan "remove $config_file if nothing outside Zolven's blocks remains"
    return 0
  fi

  local tmp
  tmp="$(mktemp "${config_file}.XXXXXX")"
  # The config holds no secrets directly, but match the 0600 convention.
  chmod 600 "$tmp" 2>/dev/null || true
  # ZOLVEN-HIMALAYA-STRIP-AWK-BEGIN
  awk '
    /^# >>> Zolven mail account: / { skip=1; next }
    /^# <<< Zolven mail account: / { skip=0; next }
    skip { next }
    { print }
  ' "$config_file" > "$tmp"
  # ZOLVEN-HIMALAYA-STRIP-AWK-END

  if grep -qE '[^[:space:]]' "$tmp"; then
    # Survivors remain — hand-added accounts, or the user's own global Himalaya
    # settings living outside Zolven's fences. Keep the file, drop only Zolven's
    # blocks.
    mv "$tmp" "$config_file"
    chmod 600 "$config_file" 2>/dev/null || true
    ok "Removed Zolven-managed mail accounts from $config_file"
  else
    # Nothing but blank lines left — Zolven owned the whole file. Remove it and
    # prune an empty dir.
    rm -f "$tmp" "$config_file"
    ok "Removed Zolven-managed Himalaya config ($config_file)"
    rmdir "$(dirname "$config_file")" 2>/dev/null || true
  fi
}

stage_remove_repo() {
  [ "$KEEP_REPO" -eq 0 ] || { say "Keeping repo (--keep-repo)"; return 0; }
  if ! path_is_zolven_removal_target "$REPO_DIR"; then
    warn "Repo path is outside Zolven ownership; skipping: $REPO_DIR"
    return 0
  fi
  if [ ! -d "$REPO_DIR" ]; then
    return 0
  fi
  if [ ! -d "$REPO_DIR/.git" ]; then
    warn "Repo dir $REPO_DIR is not a git checkout; skipping to stay safe."
    return 0
  fi
  if ! repo_origin_is_zolven; then
    warn "Repo at $REPO_DIR does not target Zolven/zolven; skipping."
    return 0
  fi
  if [ ! -f "$REPO_DIR/scripts/install.sh" ] && [ ! -f "$REPO_DIR/scripts/install-openclaw.sh" ]; then
    warn "Repo at $REPO_DIR does not look like the Zolven repo (missing scripts/install.sh); skipping."
    return 0
  fi
  rm_path "$REPO_DIR" "Zolven repo checkout"
}

stage_purge_intelligence_cli() {
  [ "$PURGE_INTELLIGENCE_CLI" -eq 1 ] || return 0
  if ! command -v npm >/dev/null 2>&1; then
    say "npm not found, cannot uninstall Zolven Intelligence"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    plan "remove Zolven Intelligence CLI from the user-local npm prefix"
    plan "remove Zolven Intelligence CLI from the global npm prefix"
    return 0
  fi
  say "Uninstalling Zolven Intelligence CLI"
  npm uninstall -g --prefix "$HOME/.local" "@zolven/zolven-intelligence" >/dev/null 2>&1 || true
  npm uninstall -g "@zolven/zolven-intelligence" >/dev/null 2>&1 || true
}

resolve_defaults
interactive_menu
summarize

if [ "$DRY_RUN" -eq 1 ]; then
  say "Dry-run — no changes will be made."
fi

if [ "$INSTALL_MODE" = "cloud" ] && [ "$KEEP_DATA_DIR" -eq 0 ]; then
  warn "Cloud cleanup removes VM-local onboarding state, secrets, and chat history stored on this runtime."
fi

if [ "$DRY_RUN" -eq 0 ]; then
  if ! confirm "Apply the plan above?" 1; then
    say "Aborted."
    exit 0
  fi
fi

tty_header "Stopping services"
stage_cloud_decommission
stage_stop_via_cli
stage_stop_launchd
stage_stop_systemd
stage_free_ports

tty_header "Removing Zolven state"
stage_remove_env_local
stage_remove_cli_launcher
stage_remove_data_dir
stage_remove_watch_dir
stage_remove_openclaw_workspace
stage_remove_himalaya_accounts

if [ "$PURGE_INTELLIGENCE_CLI" -eq 1 ]; then
  tty_header "Purging optional components"
  stage_purge_intelligence_cli
fi

stage_remove_repo

printf '\n'
tty_rule
if [ "$DRY_RUN" -eq 1 ]; then
  ok "Dry-run complete. Re-run without --dry-run to apply."
else
  ok "Zolven cleanup complete."
  printf '\n'
  tty_note "Reinstall from scratch with:"
  printf '  %bcurl -fsSL https://raw.githubusercontent.com/Zolven/zolven-install/main/install.sh | bash%b\n\n' "$TTY_BOLD" "$TTY_RESET"
fi
