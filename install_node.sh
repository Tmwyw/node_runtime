#!/usr/bin/env bash
set -euo pipefail

NETRUN_HOME="/opt/netrun"
PROXY_ROOT="/opt/netrun/proxyserver"
JOBS_ROOT="/opt/netrun/jobs"
SERVICE_NAME="netrun-node-agent"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SYSCTL_FILE="/etc/sysctl.d/99-netrun.conf"
HEALTH_URL="http://127.0.0.1:8085/health"

CLEAN_REQUESTED=0
REMOVE_LEGACY_ROOT=0
TMP_SOURCE=""

log() {
  printf '[install_node] %s\n' "$*"
}

die() {
  printf '[install_node] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: bash install_node.sh [--clean] [--remove-legacy-root]

Options:
  --clean               Run scripts/clean_node.sh before installing.
  --remove-legacy-root  With --clean, also remove /root/proxyserver.
EOF
}

cleanup_tmp() {
  if [ -n "$TMP_SOURCE" ] && [ -d "$TMP_SOURCE" ]; then
    rm -rf "$TMP_SOURCE"
  fi
}
trap cleanup_tmp EXIT

for arg in "$@"; do
  case "$arg" in
    --clean)
      CLEAN_REQUESTED=1
      ;;
    --remove-legacy-root)
      REMOVE_LEGACY_ROOT=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $arg"
      ;;
  esac
done

if [ "${EUID}" -ne 0 ]; then
  die "must_run_as_root"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_DIR="$SCRIPT_DIR"

ensure_bundled_3proxy() {
  local root="$1"
  local binary="$root/deploy/node/bin/3proxy"
  if [ ! -f "$binary" ]; then
    die "missing_bundled_3proxy_binary: expected $binary"
  fi
}

copy_source_to_tmp() {
  TMP_SOURCE="$(mktemp -d /tmp/netrun-node-source.XXXXXX)"
  tar -C "$SOURCE_DIR" --exclude='./.git' -cf - . | tar -C "$TMP_SOURCE" -xpf -
  SOURCE_DIR="$TMP_SOURCE"
}

run_clean_if_requested() {
  if [ "$CLEAN_REQUESTED" -ne 1 ]; then
    return 0
  fi

  local source_real
  source_real="$(realpath "$SOURCE_DIR")"
  if [ "$source_real" = "$NETRUN_HOME" ] || [[ "$source_real" == "$NETRUN_HOME/"* ]]; then
    copy_source_to_tmp
  fi

  local clean_script="$SOURCE_DIR/scripts/clean_node.sh"
  [ -f "$clean_script" ] || die "clean_script_not_found: $clean_script"
  chmod +x "$clean_script" || true

  log "Running cleanup before install"
  if [ "$REMOVE_LEGACY_ROOT" -eq 1 ]; then
    bash "$clean_script" --remove-legacy-root
  else
    bash "$clean_script"
  fi
}

install_os_dependencies() {
  command -v apt-get >/dev/null 2>&1 || die "apt_get_not_found"
  export DEBIAN_FRONTEND=noninteractive
  log "Installing OS dependencies"
  apt-get update
  apt-get install -y curl wget jq ca-certificates nftables
}

node_major() {
  if ! command -v node >/dev/null 2>&1; then
    echo 0
    return
  fi
  node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0
}

install_nodejs_20_if_needed() {
  local major
  major="$(node_major)"
  if [ "$major" -ge 20 ] 2>/dev/null; then
    log "Node.js major version is $major"
  else
    export DEBIAN_FRONTEND=noninteractive
    log "Installing Node.js 20"
    apt-get install -y ca-certificates curl gnupg
    mkdir -p /etc/apt/keyrings
    rm -f /etc/apt/keyrings/nodesource.gpg
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    chmod 0644 /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list
    apt-get update
    apt-get install -y nodejs
  fi

  if [ ! -x /usr/bin/node ]; then
    local node_bin
    node_bin="$(command -v node || true)"
    [ -n "$node_bin" ] || die "node_binary_not_found_after_install"
    ln -sf "$node_bin" /usr/bin/node
  fi

  local final_major
  final_major="$(/usr/bin/node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)"
  [ "$final_major" -ge 20 ] 2>/dev/null || die "nodejs_20_required"
}

copy_repo_to_opt() {
  mkdir -p "$NETRUN_HOME"
  local source_real
  source_real="$(realpath "$SOURCE_DIR")"
  if [ "$source_real" = "$NETRUN_HOME" ]; then
    log "Using existing repo at $NETRUN_HOME"
    return 0
  fi

  log "Copying node runtime to $NETRUN_HOME"
  tar -C "$SOURCE_DIR" --exclude='./.git' -cf - . | tar -C "$NETRUN_HOME" -xpf -
}

install_runtime_files() {
  mkdir -p "$NETRUN_HOME" "$JOBS_ROOT" "$PROXY_ROOT" "$PROXY_ROOT/3proxy/bin"

  local bundled="$NETRUN_HOME/deploy/node/bin/3proxy"
  [ -f "$bundled" ] || die "missing_bundled_3proxy_binary: expected $bundled"

  install -m 0755 "$bundled" "$PROXY_ROOT/3proxy/bin/3proxy"
  chmod +x "$PROXY_ROOT/3proxy/bin/3proxy"
  chmod +x "$NETRUN_HOME/node_runtime/generator/proxyyy_automated.sh"
  chmod +x "$NETRUN_HOME/node_runtime/soft/generator/proxyyy_automated.sh"
  chmod +x "$NETRUN_HOME/scripts/"*.sh
}

configure_sysctl() {
  log "Configuring sysctl"
  cat > "$SYSCTL_FILE" <<'EOF'
net.ipv6.ip_nonlocal_bind = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
EOF
  sysctl -p "$SYSCTL_FILE" >/dev/null
}

configure_nftables() {
  log "Configuring nftables"
  systemctl enable nftables >/dev/null
  systemctl start nftables >/dev/null

  nft add table inet proxy_normalization 2>/dev/null || true
  nft add chain inet proxy_normalization output '{ type filter hook output priority -150; policy accept; }' 2>/dev/null || true
  nft add chain inet proxy_normalization postrouting '{ type filter hook postrouting priority -150; policy accept; }' 2>/dev/null || true

  nft add table inet proxy_accounting 2>/dev/null || true
  nft add chain inet proxy_accounting input '{ type filter hook input priority 0; policy accept; }' 2>/dev/null || true
  nft add chain inet proxy_accounting output '{ type filter hook output priority 0; policy accept; }' 2>/dev/null || true

  nft list ruleset > /etc/nftables.conf
}

write_bootstrap_marker() {
  log "Writing bootstrap marker"
  cat > "$PROXY_ROOT/.netrun_bootstrap.json" <<EOF
{
  "bootstrapped_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "proxy_root": "$PROXY_ROOT",
  "jobs_root": "$JOBS_ROOT",
  "bundled_3proxy": "$NETRUN_HOME/deploy/node/bin/3proxy",
  "runtime_3proxy": "$PROXY_ROOT/3proxy/bin/3proxy",
  "installer": "install_node.sh"
}
EOF
}

install_systemd_service() {
  local template="$NETRUN_HOME/deploy/node/netrun-node-agent.service.template"
  [ -f "$template" ] || die "service_template_not_found: $template"

  log "Installing systemd service"
  install -m 0644 "$template" "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null
  systemctl restart "$SERVICE_NAME"
}

verify_health() {
  log "Waiting for health ready"
  local health=""
  for _ in $(seq 1 30); do
    health="$(curl -fsS "$HEALTH_URL" 2>/dev/null || true)"
    if [ -n "$health" ] && printf '%s' "$health" | jq -e '.success == true and .status == "ready"' >/dev/null 2>&1; then
      printf '%s\n' "$health" | jq .
      return 0
    fi
    sleep 1
  done

  systemctl status "$SERVICE_NAME" --no-pager || true
  journalctl -u "$SERVICE_NAME" -n 100 --no-pager || true
  die "health_check_failed"
}

main() {
  ensure_bundled_3proxy "$SOURCE_DIR"
  run_clean_if_requested
  ensure_bundled_3proxy "$SOURCE_DIR"

  install_os_dependencies
  install_nodejs_20_if_needed
  copy_repo_to_opt
  install_runtime_files
  configure_sysctl
  configure_nftables
  write_bootstrap_marker
  install_systemd_service
  verify_health

  log "Install complete"
  log "NETRUN_HOME=$NETRUN_HOME"
  log "PROXY_ROOT=$PROXY_ROOT"
  log "JOBS_ROOT=$JOBS_ROOT"
  log "SERVICE=$SERVICE_NAME"
  log "HEALTH=$HEALTH_URL"
}

main "$@"
