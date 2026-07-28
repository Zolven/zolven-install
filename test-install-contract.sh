#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$HERE/install.sh"
CLEANUP="$HERE/cleanup.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/installer-contract.XXXXXX")"
PASS=0
FAIL=0
INTELLIGENCE_PACKAGE="@zolven/intelligence"
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
  "$INTELLIGENCE_PACKAGE"
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

home="$ROOT/home"
mkdir -p "$home"

local_summary="$(HOME="$home" bash "$INSTALLER" --summary)"
cloud_summary="$(HOME="$home" bash "$INSTALLER" --mode cloud --enrollment-token placeholder --summary)"

check_equal "$(summary_value "$local_summary" repo_slug)" "Zolven/zolven" "local contract targets Zolven/zolven"
check_equal "$(summary_value "$local_summary" runtime_contract_version)" "1" "installer requires Zolven runtime contract version 1"
check_equal "$(summary_value "$local_summary" repo_dir)" "$home/.local/opt/zolven" "local repository path matches the public contract"
check_equal "$(summary_value "$local_summary" data_dir)" "$home/.local/share/zolven" "local data path matches the public contract"
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

if grep -Fq "$INTELLIGENCE_PACKAGE" <<<"$validator_body"; then
  check 0 "runtime contract targets the exact $INTELLIGENCE_PACKAGE package identity"
else
  check 1 "runtime contract targets the exact $INTELLIGENCE_PACKAGE package identity"
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

check_equal "$(sed -n '1p' "$npm_log")" \
  "uninstall -g --prefix $cleanup_home/.local $INTELLIGENCE_PACKAGE" \
  "cleanup removes $INTELLIGENCE_PACKAGE from the user-local npm prefix"
check_equal "$(sed -n '2p' "$npm_log")" \
  "uninstall -g $INTELLIGENCE_PACKAGE" \
  "cleanup removes $INTELLIGENCE_PACKAGE from the global npm prefix"
check_equal "$(wc -l <"$npm_log" | tr -d ' ')" "2" \
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

compatible_repo="$ROOT/compatible-runtime"
mkdir -p "$compatible_repo/bin" "$compatible_repo/scripts"
git -C "$compatible_repo" init -q
: >"$compatible_repo/bin/zolven"
chmod +x "$compatible_repo/bin/zolven"
printf '%s\n' "1" >"$compatible_repo/.zolven-install-contract"
printf '%s\n' "${REQUIRED_IDENTIFIERS[@]}" >"$compatible_repo/scripts/install.sh"
git -C "$compatible_repo" add .zolven-install-contract bin/zolven scripts/install.sh
export RUNTIME_CONTRACT_VERSION=1
export REPO_DIR="$compatible_repo"
if validate_runtime_contract; then
  check 0 "runtime gate accepts an implementation that exposes the complete contract"
else
  check 1 "runtime gate accepts an implementation that exposes the complete contract"
fi

docs_only_repo="$ROOT/docs-only-runtime"
mkdir -p "$docs_only_repo/bin"
git -C "$docs_only_repo" init -q
: >"$docs_only_repo/bin/zolven"
chmod +x "$docs_only_repo/bin/zolven"
printf '%s\n' "1" >"$docs_only_repo/.zolven-install-contract"
printf '%s\n' "${REQUIRED_IDENTIFIERS[@]}" >"$docs_only_repo/README.md"
git -C "$docs_only_repo" add .zolven-install-contract bin/zolven README.md
export REPO_DIR="$docs_only_repo"
if validate_runtime_contract; then
  check 1 "runtime gate rejects identifiers that appear only in documentation"
else
  check 0 "runtime gate rejects identifiers that appear only in documentation"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
