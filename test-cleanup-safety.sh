#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP="$HERE/cleanup.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/installer-cleanup-safety.XXXXXX")"
PASS=0
FAIL=0
OWNED_LISTENER_PID=""
UNRELATED_LISTENER_PID=""

finish() {
  if [ -n "$OWNED_LISTENER_PID" ]; then
    kill "$OWNED_LISTENER_PID" 2>/dev/null || true
    wait "$OWNED_LISTENER_PID" 2>/dev/null || true
  fi
  if [ -n "$UNRELATED_LISTENER_PID" ]; then
    kill "$UNRELATED_LISTENER_PID" 2>/dev/null || true
    wait "$UNRELATED_LISTENER_PID" 2>/dev/null || true
  fi
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

make_product_tree() {
  local home="$1"
  local repo="$home/.local/opt/zolven"

  mkdir -p \
    "$repo/scripts" \
    "$home/.local/share/zolven" \
    "$home/.local/bin" \
    "$home/Documents/Zolven" \
    "$home/.openclaw/workspace/zolven" \
    "$home/.openclaw/workspace/unrelated" \
    "$home/.openclaw/secrets" \
    "$home/.config/systemd/user"

  git -C "$repo" init -q
  git -C "$repo" remote add origin https://github.com/Zolven/zolven.git
  : >"$repo/scripts/install.sh"
  : >"$home/.local/share/zolven/product-data"
  : >"$home/.local/bin/zolven"
  : >"$home/Documents/Zolven/watched-document"
  : >"$home/.openclaw/workspace/zolven/product-workspace-data"
  : >"$home/.openclaw/workspace/unrelated/keep-me"
  : >"$home/.openclaw/secrets/keep-me"
  : >"$home/.openclaw/openclaw.json"
  : >"$home/.config/systemd/user/openclaw-gateway.service"
}

dry_home="$ROOT/dry-home"
make_product_tree "$dry_home"
dry_output="$ROOT/dry-run.out"
HOME="$dry_home" ZOLVEN_SERVICE_MANAGER=manual \
  bash "$CLEANUP" --dry-run >"$dry_output" 2>&1

grep -Fq "$dry_home/.local/share/zolven" "$dry_output"
check "$?" "dry-run resolves the local Zolven data path"
grep -Fq "$dry_home/.openclaw/workspace/zolven" "$dry_output"
check "$?" "dry-run resolves only the Zolven OpenClaw workspace"
if grep -Fq "rm -rf $dry_home/.openclaw (OpenClaw home)" "$dry_output"; then
  check 1 "dry-run never plans removal of the shared OpenClaw home"
else
  check 0 "dry-run never plans removal of the shared OpenClaw home"
fi
[ -f "$dry_home/.local/share/zolven/product-data" ]
check "$?" "dry-run leaves Zolven data untouched"
[ -f "$dry_home/.openclaw/workspace/unrelated/keep-me" ]
check "$?" "dry-run leaves unrelated OpenClaw workspaces untouched"

actual_home="$ROOT/actual-home"
make_product_tree "$actual_home"
HOME="$actual_home" ZOLVEN_SERVICE_MANAGER=manual \
  bash "$CLEANUP" -y >"$ROOT/actual-run.out" 2>&1

[ ! -e "$actual_home/.local/opt/zolven" ]
check "$?" "cleanup removes the isolated Zolven repository"
[ ! -e "$actual_home/.local/share/zolven" ]
check "$?" "cleanup removes the isolated Zolven data directory"
[ ! -e "$actual_home/.openclaw/workspace/zolven" ]
check "$?" "cleanup removes the isolated Zolven OpenClaw workspace"
[ -f "$actual_home/.openclaw/workspace/unrelated/keep-me" ]
check "$?" "cleanup preserves an unrelated OpenClaw workspace"
[ -f "$actual_home/.openclaw/openclaw.json" ]
check "$?" "cleanup preserves the shared OpenClaw configuration"
[ -f "$actual_home/.config/systemd/user/openclaw-gateway.service" ]
check "$?" "cleanup preserves the upstream OpenClaw gateway unit"
[ -f "$actual_home/.openclaw/secrets/keep-me" ]
check "$?" "cleanup preserves shared OpenClaw secrets"

unsafe_home="$ROOT/unsafe-home"
unsafe_repo="$ROOT/unrelated-repo"
unsafe_data="$ROOT/unrelated-data"
unsafe_watch="$ROOT/unrelated-watch"
unsafe_launcher="$ROOT/unrelated-launcher"
mkdir -p "$unsafe_home" "$unsafe_repo/scripts" "$unsafe_data" "$unsafe_watch"
git -C "$unsafe_repo" init -q
git -C "$unsafe_repo" remote add origin https://github.com/Zolven/zolven.git
: >"$unsafe_repo/scripts/install.sh"
: >"$unsafe_data/keep-me"
: >"$unsafe_watch/keep-me"
: >"$unsafe_launcher"

HOME="$unsafe_home" \
  ZOLVEN_INSTALL_MODE=local \
  ZOLVEN_REPO_DIR="$unsafe_repo" \
  ZOLVEN_DATA_DIR="$unsafe_data" \
  ZOLVEN_WATCH_DIR="$unsafe_watch" \
  ZOLVEN_CLI_LAUNCHER="$unsafe_launcher" \
  ZOLVEN_SERVICE_MANAGER=manual \
  bash "$CLEANUP" -y >"$ROOT/unsafe-run.out" 2>&1

[ -d "$unsafe_repo" ]
check "$?" "cleanup refuses a repository path without Zolven ownership"
[ -f "$unsafe_data/keep-me" ]
check "$?" "cleanup refuses a data path without Zolven ownership"
[ -f "$unsafe_watch/keep-me" ]
check "$?" "cleanup refuses a watch path without Zolven ownership"
[ -f "$unsafe_launcher" ]
check "$?" "cleanup refuses a launcher path without Zolven ownership"

state_home="$ROOT/state-home"
state_dir="$state_home/.local/share/zolven/install"
mkdir -p "$state_dir" "$state_home/.config/systemd/user"
cat >"$state_dir/install-state.env" <<'EOF'
ZOLVEN_INSTALL_MODE=local
ZOLVEN_SERVICE_MANAGER=systemd-user
ZOLVEN_SERVICE_UNITS='zolven-api.service unrelated.service zolven-../../unrelated.service'
ZOLVEN_LAUNCHD_LABELS='ai.zolven.dashboard com.example.unrelated ai.zolven../../unrelated'
EOF
: >"$state_home/.config/systemd/user/zolven-api.service"
: >"$state_home/.config/systemd/user/unrelated.service"

HOME="$state_home" bash "$CLEANUP" --dry-run >"$ROOT/state-run.out" 2>&1
grep -Fq "Ignoring non-Zolven service unit from install state: unrelated.service" "$ROOT/state-run.out"
check "$?" "cleanup rejects non-Zolven systemd units from install state"
grep -Fq "Ignoring non-Zolven launchd label from install state: com.example.unrelated" "$ROOT/state-run.out"
check "$?" "cleanup rejects non-Zolven launchd labels from install state"
grep -Fq "Ignoring invalid Zolven service unit from install state: zolven-../../unrelated.service" "$ROOT/state-run.out"
check "$?" "cleanup rejects path traversal in systemd unit names"
grep -Fq "Ignoring invalid Zolven launchd label from install state: ai.zolven../../unrelated" "$ROOT/state-run.out"
check "$?" "cleanup rejects path traversal in launchd labels"
if grep -Eq '^plan.*unrelated\.service' "$ROOT/state-run.out"; then
  check 1 "cleanup never plans removal of a rejected service unit"
else
  check 0 "cleanup never plans removal of a rejected service unit"
fi

if command -v python3 >/dev/null 2>&1 && command -v lsof >/dev/null 2>&1; then
  listener_home="$ROOT/listener-home"
  unrelated_listener_dir="$ROOT/unrelated-listener"
  listener_output="$ROOT/listener-run.out"
  make_product_tree "$listener_home"
  mkdir -p "$unrelated_listener_dir"

  read -r owned_port unrelated_port <<EOF
$(python3 -c 'import socket; sockets=[socket.socket(), socket.socket()]; [s.bind(("127.0.0.1", 0)) for s in sockets]; print(*(s.getsockname()[1] for s in sockets)); [s.close() for s in sockets]')
EOF

  (
    cd "$listener_home/.local/opt/zolven"
    exec python3 -m http.server "$owned_port" --bind 127.0.0.1
  ) >"$ROOT/owned-listener.out" 2>&1 &
  OWNED_LISTENER_PID=$!
  (
    cd "$unrelated_listener_dir"
    exec python3 -m http.server "$unrelated_port" --bind 127.0.0.1
  ) >"$ROOT/unrelated-listener.out" 2>&1 &
  UNRELATED_LISTENER_PID=$!

  listeners_ready=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if lsof -ti "tcp:$owned_port" >/dev/null 2>&1 && lsof -ti "tcp:$unrelated_port" >/dev/null 2>&1; then
      listeners_ready=1
      break
    fi
    sleep 0.1
  done

  if [ "$listeners_ready" -eq 1 ]; then
    HOME="$listener_home" \
      ZOLVEN_SERVICE_MANAGER=manual \
      ZOLVEN_PORT="$owned_port" \
      ZOLVEN_API_PORT="$unrelated_port" \
      bash "$CLEANUP" --dry-run >"$listener_output" 2>&1

    grep -Fq "kill $OWNED_LISTENER_PID  (Zolven process still listening on :$owned_port)" "$listener_output"
    check "$?" "cleanup plans port handling for a confirmed Zolven-owned listener"
    grep -Fq "Leaving unrelated process $UNRELATED_LISTENER_PID listening on :$unrelated_port" "$listener_output"
    check "$?" "cleanup leaves an unrelated listener on a product port untouched"
    kill -0 "$OWNED_LISTENER_PID" 2>/dev/null
    check "$?" "cleanup dry-run leaves the Zolven-owned listener running"
    kill -0 "$UNRELATED_LISTENER_PID" 2>/dev/null
    check "$?" "cleanup dry-run leaves the unrelated listener running"
  else
    check 1 "cleanup listener safety fixture starts"
  fi
else
  printf 'SKIP  listener ownership checks require python3 and lsof\n'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
