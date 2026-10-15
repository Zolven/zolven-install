#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$HERE/install.sh"
CLEANUP="$HERE/cleanup.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/installer-contract.XXXXXX")"
PASS=0
FAIL=0
# A host that exports its own layout (a hand-patched shell profile does) must
# not leak it into the defaults under test.
unset ZOLVEN_DATA_DIR ZOLVEN_INSTALL_STATE_FILE ZOLVEN_REPO_DIR ZOLVEN_WATCH_DIR \
  ZOLVEN_CLI_LAUNCHER ZOLVEN_INSTALL_MODE ZOLVEN_REPO_BRANCH
# The gate requires the Intelligence integration, not a particular npm package
# name: the fork renamed its published package, so only a marker that survives
# renames on both sides is worth gating on.
INTELLIGENCE_MARKER="zolven-intelligence"
# Cleanup, by contrast, must clear every package name a machine may carry, in
# this order.
INTELLIGENCE_PACKAGES=(
  openclaw
  "@zolven/intelligence"
)
REQUIRED_IDENTIFIERS=(
  ZOLVEN_INSTALL_CONTRACT_VERSION
  ZOLVEN_REPO_DIR
  ZOLVEN_DATA_DIR
  ZOLVEN_INSTALL_MODE
  ZOLVEN_DEPLOYMENT_MODE
  ZOLVEN_OPENCLAW_WORKSPACE_DIR
  zolven-api.service
  zolven-dashboard.service
  zolven-worker.service
  zolven-worker.timer
  zolven-proxy.service
  zolven-tunnel.service
)

finish() {
  if [ -n "${ROOT:-}" ] && [ -d "$ROOT" ]; then
    rm -rf -- "$ROOT"
  fi
}
trap finish EXIT

check() {
  local status="$1" description="$2"
  if [ "$status" -eq 0 ]; then
    printf 'PASS  %s\n' "$description"
    PASS=$((PASS + 1))
  else
    printf 'FAIL  %s\n' "$description"
    FAIL=$((FAIL + 1))
  fi
}

check_equal() {
  local actual="$1" expected="$2" description="$3"
  if [ "$actual" = "$expected" ]; then
    check 0 "$description"
  else
    check 1 "$description (expected '$expected', got '$actual')"
  fi
}

summary_value() {
  local summary="$1" key="$2"
  printf '%s\n' "$summary" | awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }'
}

# The local data dir is a cross-repo contract: Zolven/zolven resolves it in
# scripts/lib/data-dir.sh, packages/cli/src/config.js and
# packages/config/src/index.ts, and pins all three to the same table in
# packages/config/tests/data-dir-contract.test.ts. Keep these in step with it.
CANONICAL_MACOS_DATA="Library/Application Support/Zolven"
LEGACY_MACOS_DATA=".local/share/zolven"
LINUX_DATA=".local/share/zolven"
INSTALL_MARKERS=(
  config/zolven.env
  data/finance_ops.sqlite
  install/install-state.env
)
case "$(uname -s)" in
  Darwin) NATIVE_LOCAL_DATA="$CANONICAL_MACOS_DATA" ;;
  *) NATIVE_LOCAL_DATA="$LINUX_DATA" ;;
esac

# Puts a `uname` first on PATH that answers `-s` with the given kernel name and
# hands every other query to the real one, so both platforms run on any runner.
REAL_UNAME="$(command -v uname)"
uname_shim_dir() {
  local kernel="$1" dir="$ROOT/uname-$1"
  if [ ! -x "$dir/uname" ]; then
    mkdir -p "$dir"
    cat >"$dir/uname" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-s" ]; then
  printf '%s\\n' "$kernel"
  exit 0
fi
exec "$REAL_UNAME" "\$@"
EOF
    chmod +x "$dir/uname"
  fi
  printf '%s\n' "$dir"
}

# Usage: data_dir_home NAME [RELATIVE_DIR:ENTRY ...]. An ENTRY ending in / is a
# directory; anything else is an empty file.
data_dir_home() {
  local home="$ROOT/data-dir/$1" spec dir entry
  shift
  mkdir -p "$home"
  for spec in "$@"; do
    dir="${spec%%:*}"
    entry="${spec#*:}"
    mkdir -p "$home/$dir"
    case "$entry" in
      "") ;;
      */) mkdir -p "$home/$dir/$entry" ;;
      *) mkdir -p "$(dirname "$home/$dir/$entry")"; : >"$home/$dir/$entry" ;;
    esac
  done
  printf '%s\n' "$home"
}

summary_as() {
  local kernel="$1" home="$2"
  shift 2
  PATH="$(uname_shim_dir "$kernel"):$PATH" HOME="$home" bash "$INSTALLER" "$@" --summary
}

home="$ROOT/home"
mkdir -p "$home"

local_summary="$(HOME="$home" bash "$INSTALLER" --summary)"
cloud_summary="$(HOME="$home" bash "$INSTALLER" --mode cloud --enrollment-token placeholder --summary)"

check_equal "$(summary_value "$local_summary" repo_slug)" "Zolven/zolven" "local contract targets Zolven/zolven"
check_equal "$(summary_value "$local_summary" runtime_contract_version)" "1" "installer requires Zolven runtime contract version 1"
check_equal "$(summary_value "$local_summary" repo_dir)" "$home/.local/opt/zolven" "local repository path matches the public contract"
check_equal "$(summary_value "$local_summary" data_dir)" "$home/$NATIVE_LOCAL_DATA" "local data path matches the public contract"
check_equal "$(summary_value "$local_summary" openclaw_workspace_dir)" "$home/.openclaw/workspace/zolven" "local OpenClaw workspace is product-scoped"
case "$(summary_value "$local_summary" cli_launcher)" in
  "$home/.local/bin/zolven"|/usr/local/bin/zolven) check 0 "local CLI launcher matches an allowed contract path" ;;
  *) check 1 "local CLI launcher matches an allowed contract path" ;;
esac

check_equal "$(summary_value "$cloud_summary" repo_dir)" "/opt/zolven" "cloud repository path matches the public contract"
check_equal "$(summary_value "$cloud_summary" data_dir)" "/var/lib/zolven" "cloud data path matches the public contract"
check_equal "$(summary_value "$cloud_summary" cli_launcher)" "/usr/local/bin/zolven" "cloud CLI launcher matches the public contract"
check_equal "$(summary_value "$cloud_summary" openclaw_workspace_dir)" "/var/lib/zolven/openclaw/workspace/zolven" "cloud OpenClaw workspace is product-scoped"
check_equal "$(summary_value "$cloud_summary" cloud_service_user)" "zolven" "cloud service user is Zolven-owned"
check_equal "$(summary_value "$cloud_summary" service_units)" "zolven-api.service zolven-dashboard.service zolven-worker.service zolven-worker.timer zolven-proxy.service zolven-tunnel.service" "cloud service units use the Zolven namespace"

state_file="$ROOT/install-state.env"
printf '%s\n' \
  'ZOLVEN_INSTALL_MODE=cloud' \
  'ZOLVEN_REPO_REF=release-zolven' \
  >"$state_file"

reused_cloud_summary="$(
  HOME="$home" \
    ZOLVEN_INSTALL_STATE_FILE="$state_file" \
    bash "$INSTALLER" --mode cloud --enrollment-token placeholder --summary
)"
check_equal "$(summary_value "$reused_cloud_summary" branch)" "release-zolven" \
  "cloud rerun restores the runtime ref recorded in install state"

env_override_summary="$(
  HOME="$home" \
    ZOLVEN_INSTALL_STATE_FILE="$state_file" \
    ZOLVEN_REPO_BRANCH="env-override" \
    bash "$INSTALLER" --mode cloud --enrollment-token placeholder --summary
)"
check_equal "$(summary_value "$env_override_summary" branch)" "env-override" \
  "explicit branch environment overrides the recorded runtime ref"

cli_override_summary="$(
  HOME="$home" \
    ZOLVEN_INSTALL_STATE_FILE="$state_file" \
    bash "$INSTALLER" --mode cloud --enrollment-token placeholder --branch "cli-override" --summary
)"
check_equal "$(summary_value "$cli_override_summary" branch)" "cli-override" \
  "explicit branch argument overrides the recorded runtime ref"

mode_switch_summary="$(
  HOME="$home" \
    ZOLVEN_INSTALL_STATE_FILE="$state_file" \
    bash "$INSTALLER" --summary
)"
check_equal "$(summary_value "$mode_switch_summary" branch)" "main" \
  "switching install mode does not inherit the previous mode runtime ref"

adopt_home="$ROOT/adopt-home"
mkdir -p "$adopt_home"
adopt_state_file="$ROOT/adopt-install-state.env"
adopt_repo_dir="$ROOT/adopted/opt/zolven"
adopt_data_dir="$ROOT/adopted/share/zolven"
adopt_watch_dir="$ROOT/adopted/watch"
adopt_cli_launcher="$ROOT/adopted/bin/zolven"
printf '%s\n' \
  'ZOLVEN_INSTALL_MODE=local' \
  "ZOLVEN_REPO_DIR=$adopt_repo_dir" \
  "ZOLVEN_DATA_DIR=$adopt_data_dir" \
  "ZOLVEN_WATCH_DIR=$adopt_watch_dir" \
  "ZOLVEN_CLI_LAUNCHER=$adopt_cli_launcher" \
  >"$adopt_state_file"

adopted_summary="$(
  HOME="$adopt_home" \
    ZOLVEN_INSTALL_STATE_FILE="$adopt_state_file" \
    bash "$INSTALLER" --summary
)"
check_equal "$(summary_value "$adopted_summary" existing_install)" "1" \
  "rerun reports the existing install recorded in install state"
check_equal "$(summary_value "$adopted_summary" repo_dir)" "$adopt_repo_dir" \
  "rerun adopts the repository path recorded in install state"
check_equal "$(summary_value "$adopted_summary" data_dir)" "$adopt_data_dir" \
  "rerun adopts the data path recorded in install state"
check_equal "$(summary_value "$adopted_summary" watch_dir)" "$adopt_watch_dir" \
  "rerun adopts the watch path recorded in install state"
check_equal "$(summary_value "$adopted_summary" cli_launcher)" "$adopt_cli_launcher" \
  "rerun adopts the CLI launcher recorded in install state"
check_equal "$(summary_value "$adopted_summary" cloud_env_file)" "$adopt_data_dir/config/cloud-bootstrap.env" \
  "rerun re-derives data-relative files against the adopted data path"

path_override_summary="$(
  HOME="$adopt_home" \
    ZOLVEN_INSTALL_STATE_FILE="$adopt_state_file" \
    ZOLVEN_REPO_DIR="$ROOT/override/zolven" \
    bash "$INSTALLER" --summary
)"
check_equal "$(summary_value "$path_override_summary" repo_dir)" "$ROOT/override/zolven" \
  "explicit repository environment overrides the recorded install path"
check_equal "$(summary_value "$path_override_summary" data_dir)" "$adopt_data_dir" \
  "overriding one path still adopts the remaining recorded layout"

path_mode_switch_summary="$(
  HOME="$adopt_home" \
    ZOLVEN_INSTALL_STATE_FILE="$adopt_state_file" \
    bash "$INSTALLER" --mode cloud --enrollment-token placeholder --summary
)"
check_equal "$(summary_value "$path_mode_switch_summary" repo_dir)" "/opt/zolven" \
  "switching install mode keeps the new mode default repository path"
check_equal "$(summary_value "$path_mode_switch_summary" data_dir)" "/var/lib/zolven" \
  "switching install mode keeps the new mode default data path"

fresh_summary="$(
  HOME="$adopt_home" \
    ZOLVEN_INSTALL_STATE_FILE="$ROOT/absent-install-state.env" \
    bash "$INSTALLER" --summary
)"
check_equal "$(summary_value "$fresh_summary" existing_install)" "0" \
  "fresh run reports no existing install"
check_equal "$(summary_value "$fresh_summary" repo_dir)" "$adopt_home/.local/opt/zolven" \
  "fresh run keeps the mode default repository path"

# macOS keeps the canonical location, but installs this installer placed in
# ~/.local/share/zolven are adopted where they are rather than orphaned.
check_data_dir_as() {
  local kernel="$1" expected="$2" description="$3" home
  shift 3
  home="$(data_dir_home "$kernel-$((PASS + FAIL))" "$@")"
  check_equal "$(summary_value "$(summary_as "$kernel" "$home")" data_dir)" "$home/$expected" \
    "$description"
}

if [ "$(PATH="$(uname_shim_dir Darwin):$PATH" uname -s)" = "Darwin" ] \
  && [ "$(PATH="$(uname_shim_dir Linux):$PATH" uname -s)" = "Linux" ]; then
  check 0 "uname shim impersonates the platform under test"
else
  check 1 "uname shim impersonates the platform under test"
fi

check_data_dir_as Darwin "$CANONICAL_MACOS_DATA" \
  "macOS fresh install uses Application Support"
for marker in "${INSTALL_MARKERS[@]}"; do
  check_data_dir_as Darwin "$LEGACY_MACOS_DATA" \
    "macOS adopts a ~/.local/share/zolven install recorded by $marker" \
    "$LEGACY_MACOS_DATA:$marker"
done
check_data_dir_as Darwin "$CANONICAL_MACOS_DATA" \
  "macOS ignores an empty ~/.local/share/zolven" \
  "$LEGACY_MACOS_DATA:"
check_data_dir_as Darwin "$LEGACY_MACOS_DATA" \
  "macOS ignores an empty Application Support dir next to a legacy install" \
  "$CANONICAL_MACOS_DATA:logs/" "$LEGACY_MACOS_DATA:config/zolven.env"
check_data_dir_as Darwin "$CANONICAL_MACOS_DATA" \
  "macOS keeps an Application Support install" \
  "$CANONICAL_MACOS_DATA:config/zolven.env"

# With an install in both places the rule itself ranks them (database first,
# then the installer's own state record), as the runtime does; the installer
# then refuses to act on it anyway (below), because its wrong guess is the
# destructive one.
data_dir_functions="$ROOT/data-dir-functions.sh"
awk '
  /^data_dir_has_install\(\) \{/ || /^data_dir_rank\(\) \{/ || /^default_local_data_dir\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}/ { capture=0 }
' "$INSTALLER" >"$data_dir_functions"
check_default_rule_as_darwin() {
  local expected="$1" description="$2" home
  shift 2
  home="$(data_dir_home "rule-$((PASS + FAIL))" "$@")"
  check_equal \
    "$(PATH="$(uname_shim_dir Darwin):$PATH" HOME="$home" bash -c '. "$1"; default_local_data_dir' _ "$data_dir_functions")" \
    "$home/$expected" "$description"
}
check_default_rule_as_darwin "$LEGACY_MACOS_DATA" \
  "macOS rule keeps a recorded legacy install over a stray Application Support env file" \
  "$LEGACY_MACOS_DATA:install/install-state.env" "$LEGACY_MACOS_DATA:data/finance_ops.sqlite" \
  "$CANONICAL_MACOS_DATA:config/zolven.env"
check_default_rule_as_darwin "$LEGACY_MACOS_DATA" \
  "macOS rule keeps an unrecorded legacy install over a stray Application Support env file" \
  "$LEGACY_MACOS_DATA:config/zolven.env" "$LEGACY_MACOS_DATA:data/finance_ops.sqlite" \
  "$CANONICAL_MACOS_DATA:config/zolven.env"
check_default_rule_as_darwin "$CANONICAL_MACOS_DATA" \
  "macOS rule keeps an Application Support install over an aborted legacy run's state record" \
  "$CANONICAL_MACOS_DATA:config/zolven.env" "$CANONICAL_MACOS_DATA:data/finance_ops.sqlite" \
  "$LEGACY_MACOS_DATA:install/install-state.env"
check_default_rule_as_darwin "$LEGACY_MACOS_DATA" \
  "macOS rule breaks a two-database tie on the install state" \
  "$CANONICAL_MACOS_DATA:config/zolven.env" "$CANONICAL_MACOS_DATA:data/finance_ops.sqlite" \
  "$LEGACY_MACOS_DATA:install/install-state.env" "$LEGACY_MACOS_DATA:data/finance_ops.sqlite"
check_default_rule_as_darwin "$CANONICAL_MACOS_DATA" \
  "macOS rule prefers Application Support when both carry install state" \
  "$LEGACY_MACOS_DATA:install/install-state.env" "$CANONICAL_MACOS_DATA:install/install-state.env"
check_default_rule_as_darwin "$CANONICAL_MACOS_DATA" \
  "macOS rule prefers an Application Support database over a legacy env file" \
  "$CANONICAL_MACOS_DATA:data/finance_ops.sqlite" "$LEGACY_MACOS_DATA:config/zolven.env"

conflict_home="$(data_dir_home conflict \
  "$LEGACY_MACOS_DATA:install/install-state.env" "$LEGACY_MACOS_DATA:data/finance_ops.sqlite" \
  "$CANONICAL_MACOS_DATA:config/zolven.env")"
conflict_status=0
conflict_output="$(summary_as Darwin "$conflict_home" 2>&1)" || conflict_status=$?
if [ "$conflict_status" -ne 0 ] \
  && grep -Fq "$conflict_home/$LEGACY_MACOS_DATA (install state, database)" <<<"$conflict_output" \
  && grep -Fq "$conflict_home/$CANONICAL_MACOS_DATA (env file)" <<<"$conflict_output" \
  && grep -Fq -- "--data-dir" <<<"$conflict_output"; then
  check 0 "macOS installer refuses to choose between two installs and names what each holds"
else
  check 1 "macOS installer refuses to choose between two installs and names what each holds"
fi
check_equal \
  "$(summary_value "$(summary_as Darwin "$conflict_home" --data-dir "$conflict_home/$LEGACY_MACOS_DATA")" data_dir)" \
  "$conflict_home/$LEGACY_MACOS_DATA" \
  "an explicit --data-dir settles a two-install conflict"
check_data_dir_as Linux "$LINUX_DATA" \
  "Linux always uses ~/.local/share/zolven" \
  "$CANONICAL_MACOS_DATA:config/zolven.env"

# The migrated Mac mini: its install state lives under the legacy location and
# records that layout, so a bare rerun converges on it instead of setting up a
# second, empty install under Application Support.
legacy_home="$(data_dir_home legacy-state)"
legacy_data="$legacy_home/$LEGACY_MACOS_DATA"
mkdir -p "$legacy_data/install"
printf '%s\n' \
  'ZOLVEN_INSTALL_MODE=local' \
  "ZOLVEN_REPO_DIR=$legacy_home/.local/opt/zolven" \
  "ZOLVEN_DATA_DIR=$legacy_data" \
  "ZOLVEN_WATCH_DIR=$legacy_home/Documents/Kept" \
  >"$legacy_data/install/install-state.env"
legacy_summary="$(summary_as Darwin "$legacy_home")"
check_equal "$(summary_value "$legacy_summary" existing_install)" "1" \
  "macOS rerun finds the install state of a ~/.local/share/zolven install"
check_equal "$(summary_value "$legacy_summary" data_dir)" "$legacy_data" \
  "macOS rerun keeps a ~/.local/share/zolven install in place"
check_equal "$(summary_value "$legacy_summary" watch_dir)" "$legacy_home/Documents/Kept" \
  "macOS rerun adopts the rest of the legacy install's recorded layout"

cleanup_plan_as() {
  local kernel="$1" home="$2"
  shift 2
  PATH="$(uname_shim_dir "$kernel"):$PATH" HOME="$home" ZOLVEN_SERVICE_MANAGER=manual \
    bash "$CLEANUP" --dry-run "$@" 2>&1
}
if grep -Fq "rm -rf $(printf '%q' "$legacy_data") (data dir)" <<<"$(cleanup_plan_as Darwin "$legacy_home")"; then
  check 0 "macOS cleanup finds a ~/.local/share/zolven install"
else
  check 1 "macOS cleanup finds a ~/.local/share/zolven install"
fi
# A cleanup that reports success must not leave an install behind in the other
# default location, whichever one the rule picked.
both_cleanup_home="$(data_dir_home both-cleanup \
  "$LEGACY_MACOS_DATA:install/install-state.env" "$LEGACY_MACOS_DATA:data/finance_ops.sqlite" \
  "$CANONICAL_MACOS_DATA:config/zolven.env")"
both_cleanup_plan="$(cleanup_plan_as Darwin "$both_cleanup_home")"
for location in "$LEGACY_MACOS_DATA" "$CANONICAL_MACOS_DATA"; do
  if grep -Fq "rm -rf $(printf '%q' "$both_cleanup_home/$location")" <<<"$both_cleanup_plan"; then
    check 0 "macOS cleanup plans removal of $location when both locations exist"
  else
    check 1 "macOS cleanup plans removal of $location when both locations exist"
  fi
done
kept_cleanup_plan="$(cleanup_plan_as Darwin "$both_cleanup_home" --keep-data-dir)"
if grep -Eq '\((other default )?data dir\)$' <<<"$kept_cleanup_plan"; then
  check 1 "--keep-data-dir keeps both macOS data locations"
else
  check 0 "--keep-data-dir keeps both macOS data locations"
fi

canonical_cleanup_home="$(data_dir_home canonical-cleanup "$CANONICAL_MACOS_DATA:install/install-state.env")"
if grep -Fq "rm -rf $(printf '%q' "$canonical_cleanup_home/$CANONICAL_MACOS_DATA") (data dir)" <<<"$(cleanup_plan_as Darwin "$canonical_cleanup_home")"; then
  check 0 "macOS cleanup targets an Application Support install"
else
  check 1 "macOS cleanup targets an Application Support install"
fi

if grep -Fq "run_quiet \"repository clone\" gh repo clone \"\$REPO_SLUG\"" "$INSTALLER"; then
  check 0 "runtime cloning is delegated to GitHub CLI"
else
  check 1 "runtime cloning is delegated to GitHub CLI"
fi

clone_line="$(grep -n 'run_quiet "repository clone" gh repo clone' "$INSTALLER" | tail -n 1 | cut -d: -f1)"
validator_line="$(grep -n '^validate_runtime_contract$' "$INSTALLER" | cut -d: -f1)"
runtime_line="$(grep -n '^if ! invoke_runtime_install; then$' "$INSTALLER" | cut -d: -f1)"
if [ -n "$clone_line" ] && [ -n "$validator_line" ] && [ -n "$runtime_line" ] \
  && [ "$clone_line" -lt "$validator_line" ] && [ "$validator_line" -lt "$runtime_line" ]; then
  check 0 "runtime contract validation blocks installation before runtime execution"
else
  check 1 "runtime contract validation blocks installation before runtime execution"
fi

remote_validator_line="$(grep -n '^validate_remote_runtime_contract$' "$INSTALLER" | cut -d: -f1)"
enrollment_line="$(grep -n '^  enroll_cloud_runtime$' "$INSTALLER" | cut -d: -f1)"
if [ -n "$remote_validator_line" ] && [ -n "$enrollment_line" ] \
  && [ "$remote_validator_line" -lt "$enrollment_line" ]; then
  check 0 "remote contract handshake blocks cloud enrollment"
else
  check 1 "remote contract handshake blocks cloud enrollment"
fi

validator_body="$(awk '
  /^validate_runtime_contract\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$INSTALLER")"

if grep -Fq 'bin/zolven' <<<"$validator_body"; then
  check 0 "runtime gate requires bin/zolven"
else
  check 1 "runtime gate requires bin/zolven"
fi
for required_identifier in "${REQUIRED_IDENTIFIERS[@]}"; do
  if grep -Fq "$required_identifier" <<<"$validator_body"; then
    check 0 "runtime gate requires $required_identifier"
  else
    check 1 "runtime gate requires $required_identifier"
  fi
done

if grep -Fq "$INTELLIGENCE_MARKER" <<<"$validator_body"; then
  check 0 "runtime gate requires the $INTELLIGENCE_MARKER integration marker"
else
  check 1 "runtime gate requires the $INTELLIGENCE_MARKER integration marker"
fi

remote_contract_function="$ROOT/remote-contract-function.sh"
awk '
  /^validate_remote_runtime_contract\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$INSTALLER" >"$remote_contract_function"
# shellcheck disable=SC1090
. "$remote_contract_function"

remote_contract_log="$ROOT/remote-contract.log"
REMOTE_CONTRACT_VERSION="1"
gh() {
  printf '%s\n' "$*" >>"$remote_contract_log"
  printf '%s' "$REMOTE_CONTRACT_VERSION"
}
# shellcheck disable=SC2317,SC2329
fail() { return 1; }
# shellcheck disable=SC2034
REPO_SLUG="Zolven/zolven"
# shellcheck disable=SC2034
RUNTIME_CONTRACT_VERSION="1"

if validate_remote_runtime_contract "release-zolven"; then
  check 0 "remote runtime gate accepts the required contract version"
else
  check 1 "remote runtime gate accepts the required contract version"
fi
if grep -Fq "ref=release-zolven" "$remote_contract_log"; then
  check 0 "remote runtime gate validates the selected runtime ref"
else
  check 1 "remote runtime gate validates the selected runtime ref"
fi

REMOTE_CONTRACT_VERSION="0"
if validate_remote_runtime_contract "incompatible-ref"; then
  check 1 "remote runtime gate rejects an incompatible contract version"
else
  check 0 "remote runtime gate rejects an incompatible contract version"
fi

enrollment_body="$(awk '
  /^enroll_cloud_runtime\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$INSTALLER")"
# shellcheck disable=SC2016
override_line="$(grep -n 'maybe_override_branch_from_enrollment "\$response"' <<<"$enrollment_body" | cut -d: -f1)"
# shellcheck disable=SC2016
selected_ref_gate_line="$(grep -n 'validate_remote_runtime_contract "\$BRANCH"' <<<"$enrollment_body" | cut -d: -f1)"
persist_line="$(grep -n '^  persist_cloud_config$' <<<"$enrollment_body" | tail -n 1 | cut -d: -f1)"
if [ -n "$override_line" ] && [ -n "$selected_ref_gate_line" ] && [ -n "$persist_line" ] \
  && [ "$override_line" -lt "$selected_ref_gate_line" ] && [ "$selected_ref_gate_line" -lt "$persist_line" ]; then
  check 0 "enrollment-selected runtime ref is validated before bootstrap persistence"
else
  check 1 "enrollment-selected runtime ref is validated before bootstrap persistence"
fi

npm_stub_dir="$ROOT/npm-stub"
npm_log="$ROOT/npm.log"
cleanup_home="$ROOT/cleanup-home"
mkdir -p "$npm_stub_dir" "$cleanup_home"
cat >"$npm_stub_dir/npm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NPM_LOG"
EOF
chmod +x "$npm_stub_dir/npm"

HOME="$cleanup_home" \
  PATH="$npm_stub_dir:$PATH" \
  NPM_LOG="$npm_log" \
  ZOLVEN_SERVICE_MANAGER=manual \
  bash "$CLEANUP" -y \
    --keep-repo \
    --keep-data-dir \
    --keep-watch-dir \
    --keep-intelligence-workspace \
    --keep-cloud-registration \
    --purge-intelligence-cli \
    >/dev/null

# Cleanup must clear both package identities: a box upgraded across the fork's
# rename carries the old name, the new name, or both.
npm_line=0
for intelligence_package in "${INTELLIGENCE_PACKAGES[@]}"; do
  npm_line=$((npm_line + 1))
  check_equal "$(sed -n "${npm_line}p" "$npm_log")" \
    "uninstall -g --prefix $cleanup_home/.local $intelligence_package" \
    "cleanup removes $intelligence_package from the user-local npm prefix"
  npm_line=$((npm_line + 1))
  check_equal "$(sed -n "${npm_line}p" "$npm_log")" \
    "uninstall -g $intelligence_package" \
    "cleanup removes $intelligence_package from the global npm prefix"
done
check_equal "$(wc -l <"$npm_log" | tr -d ' ')" "$npm_line" \
  "cleanup invokes no additional npm package removals"

contract_functions="$ROOT/runtime-contract-functions.sh"
awk '
  /^runtime_contract_has\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}/ {
    closings += 1
    if (closings == 2) exit
  }
' "$INSTALLER" >"$contract_functions"
# shellcheck disable=SC1090
. "$contract_functions"
fail() { return 1; }

# Builds a runtime checkout that declares the given identifiers in one file, so
# the gate can be exercised against real and documentation-only layouts.
build_contract_repo() {
  local dir="$1" declaration_file="$2"
  shift 2
  mkdir -p "$dir/bin" "$dir/$(dirname "$declaration_file")"
  git -C "$dir" init -q
  : >"$dir/bin/zolven"
  chmod +x "$dir/bin/zolven"
  printf '%s\n' "1" >"$dir/.zolven-install-contract"
  printf '%s\n' "$@" >"$dir/$declaration_file"
  git -C "$dir" add .zolven-install-contract bin/zolven "$declaration_file"
}

export RUNTIME_CONTRACT_VERSION=1

compatible_repo="$ROOT/compatible-runtime"
build_contract_repo "$compatible_repo" scripts/install.sh \
  "${REQUIRED_IDENTIFIERS[@]}" "$INTELLIGENCE_MARKER"
export REPO_DIR="$compatible_repo"
if validate_runtime_contract; then
  check 0 "runtime gate accepts an implementation that exposes the complete contract"
else
  check 1 "runtime gate accepts an implementation that exposes the complete contract"
fi

# A runtime that carries no Intelligence integration at all is blocked, and no
# npm package name substitutes for the marker.
no_intelligence_repo="$ROOT/no-intelligence-runtime"
build_contract_repo "$no_intelligence_repo" scripts/install.sh \
  "${REQUIRED_IDENTIFIERS[@]}" "${INTELLIGENCE_PACKAGES[@]}"
export REPO_DIR="$no_intelligence_repo"
if validate_runtime_contract; then
  check 1 "runtime gate rejects a runtime without the $INTELLIGENCE_MARKER integration"
else
  check 0 "runtime gate rejects a runtime without the $INTELLIGENCE_MARKER integration"
fi

docs_only_repo="$ROOT/docs-only-runtime"
build_contract_repo "$docs_only_repo" README.md \
  "${REQUIRED_IDENTIFIERS[@]}" "$INTELLIGENCE_MARKER"
export REPO_DIR="$docs_only_repo"
if validate_runtime_contract; then
  check 1 "runtime gate rejects identifiers that appear only in documentation"
else
  check 0 "runtime gate rejects identifiers that appear only in documentation"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
