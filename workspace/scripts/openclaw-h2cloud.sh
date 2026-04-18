#!/usr/bin/env bash
# openclaw-h2cloud.sh — H2Cloud OpenClaw Installer v3.10
# Giai đoạn 1: Kiểm tra môi trường
# Giai đoạn 2: Cài Node.js + OpenClaw
# Giai đoạn 3: Setup config + kích hoạt key H2Cloud
# Cách dùng: curl -fsSL https://kvm.h2cloud.vn/downloads/openclaw-h2cloud.sh | bash
#         Hoặc: BOT_TOKEN=xxx TG_ALLOW_FROM="id1,id2" bash openclaw-h2cloud.sh

set -euo pipefail

INSTALLER_VERSION="v3.10"

# Xóa màn hình cho gọn nếu đang chạy trong terminal tương tác
if [[ -t 1 ]]; then
  clear || true
fi

PROVIDER_NAME="h2cloud"
BASE_URL="https://api.loadip.com/v1"
MODEL_ID="cx/gpt-5.3-codex"
API_KEY_FIXED="sk-80c6f26e1d3336a7-5ahrqn-6975d32c"
DEFAULT_MODELS_JSON='[
  {"id":"cx/gpt-5.4","name":"cx/gpt-5.4"},
  {"id":"cx/gpt-5.3-codex","name":"cx/gpt-5.3-codex"},
  {"id":"cx/gpt-5.3-codex-xhigh","name":"cx/gpt-5.3-codex-xhigh"},
  {"id":"cx/gpt-5.3-codex-high","name":"cx/gpt-5.3-codex-high"},
  {"id":"cx/gpt-5.2-codex","name":"cx/gpt-5.2-codex"},
  {"id":"h2cloud","name":"h2cloud"}
]'

OPENCLAW_CONFIG="/root/.openclaw/openclaw.json"
NODE_VERSION="22"
OPENCLAW_PORT="3080"
REQUIRED_PORTS=("$OPENCLAW_PORT")

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*"; }

# Log file: tạo mới nếu chưa có, ghi thêm nếu đã có
mkdir -p /var/log 2>/dev/null || true
LOG_FILE="/var/log/openclaw-h2cloud.log"
if ! touch "$LOG_FILE" >/dev/null 2>&1; then
  LOG_FILE="/tmp/openclaw-h2cloud.log"
  touch "$LOG_FILE"
fi
exec > >(tee -a "$LOG_FILE") 2>&1

ERRORS=0
flag_err() { err "$1"; ERRORS=$((ERRORS+1)); }

echo ""
echo "============================================="
echo "   H2Cloud OpenClaw — Trình cài đặt ${INSTALLER_VERSION}"
echo "============================================="
echo "Log: $LOG_FILE"
echo ""

# ─────────────────────────────────────────────────
# GIAI ĐOẠN 1: KIỂM TRA MÔI TRƯỜNG
# ─────────────────────────────────────────────────
echo -e "${CYAN}▶ Giai đoạn 1/3: Kiểm tra môi trường${NC}"
echo ""

# 1.1 Hệ điều hành
OS_ID=""
OS_VER=""
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_VER="${VERSION_ID:-}"
fi

case "$OS_ID" in
  ubuntu)
    ok "Hệ điều hành: Ubuntu $OS_VER"
    PKG_MGR="apt"
    ;;
  debian)
    ok "Hệ điều hành: Debian $OS_VER"
    PKG_MGR="apt"
    ;;
  centos|rhel|almalinux|rocky)
    warn "Hệ điều hành: $OS_ID $OS_VER — hỗ trợ hạn chế (khuyến nghị Ubuntu)"
    PKG_MGR="yum"
    ;;
  *)
    flag_err "Hệ điều hành không được hỗ trợ: ${OS_ID:-unknown}. Khuyến nghị Ubuntu 20.04/22.04/24.04."
    PKG_MGR="unknown"
    ;;
esac

# 1.2 Kiến trúc CPU
ARCH="$(uname -m)"
if [[ "$ARCH" == "x86_64" || "$ARCH" == "aarch64" ]]; then
  ok "Kiến trúc: $ARCH"
else
  flag_err "Kiến trúc không được hỗ trợ: $ARCH (cần x86_64 hoặc aarch64)"
fi

# 1.3 CPU core
CPU_CORES=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
ok "CPU cores: ${CPU_CORES}"

# 1.4 RAM tối thiểu 512MB
RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
if [[ "$RAM_MB" -ge 512 ]]; then
  ok "RAM: ${RAM_MB}MB (đủ)"
else
  flag_err "RAM quá thấp: ${RAM_MB}MB (cần ít nhất 512MB)"
fi

# 1.5 Disk tối thiểu 500MB free
DISK_FREE_MB=$(df / | awk 'NR==2 {printf "%d", $4/1024}')
if [[ "$DISK_FREE_MB" -ge 500 ]]; then
  ok "Disk free: ${DISK_FREE_MB}MB (đủ)"
else
  flag_err "Dung lượng trống không đủ: ${DISK_FREE_MB}MB (cần ít nhất 500MB)"
fi

# 1.5 Quyền root
if [[ "$EUID" -ne 0 ]]; then
  flag_err "Cần chạy với quyền root (sudo bash $0)"
else
  ok "Quyền: root"
fi

# 1.6 Kết nối internet
if curl -s --max-time 8 https://registry.npmjs.org/ >/dev/null 2>&1; then
  ok "Kết nối internet: OK"
else
  flag_err "Không có kết nối internet — cần kết nối để tải Node.js và OpenClaw"
fi

# 1.7 Kiểm tra cổng
info "Kiểm tra cổng Gateway OpenClaw (mặc định 3080)..."
for port in "${REQUIRED_PORTS[@]}"; do
  OCCUPANT=""
  if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
    OCCUPANT="$(ss -tlnp 2>/dev/null | grep ":${port} " | awk '{print $NF}' | head -1)"
  fi
  if [[ -n "$OCCUPANT" ]]; then
    flag_err "Cổng $port đang bị chiếm ($OCCUPANT) — vui lòng giải phóng trước khi cài"
  else
    ok "Cổng $port: rảnh"
  fi
done

# 1.8 systemd
if ! command -v systemctl >/dev/null 2>&1; then
  flag_err "Cần systemd để quản lý service (systemctl không tìm thấy)"
else
  ok "systemd: có"
fi

# 1.9 Kiểm tra OpenClaw đã cài chưa
ALREADY_INSTALLED=0
INSTALLED_VER=""
if command -v openclaw >/dev/null 2>&1; then
  INSTALLED_VER="$(openclaw --version 2>/dev/null | head -1 || echo 'unknown')"
  ALREADY_INSTALLED=1
  warn "OpenClaw đã cài: $INSTALLED_VER"
fi

# Tổng kết check
echo ""
if [[ "$ERRORS" -gt 0 ]]; then
  err "Kiểm tra thất bại: $ERRORS lỗi. Vui lòng khắc phục trước khi tiếp tục."
  exit 1
fi
ok "Tất cả kiểm tra đã qua"
echo ""

# ─────────────────────────────────────────────────
# GIAI ĐOẠN 2: CÀI NODE.JS + OPENCLAW
# ─────────────────────────────────────────────────
echo -e "${CYAN}[Giai đoạn 2/3: Cài đặt]${NC}"
echo ""

# 2.1 Cài jq nếu chưa có (cần cho giai đoạn 3)
if ! command -v jq >/dev/null 2>&1; then
  info "Cài jq..."
  if [[ "$PKG_MGR" == "apt" ]]; then
    # Lần 1: cài từ cache hiện có (bỏ qua lỗi)
    DEBIAN_FRONTEND=noninteractive apt-get install -y jq >/dev/null 2>&1 || true
    # Nếu vẫn chưa có (cache cũ / mirror chậm) — update rồi cài lại với timeout + force IPv4
    if ! command -v jq >/dev/null 2>&1; then
      warn "jq chưa có — chạy apt-get update rồi thử lại..."
      timeout 90 apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=1 -o Acquire::http::Timeout=20 update -qq >/dev/null 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y jq >/dev/null 2>&1 || true
    fi
  elif [[ "$PKG_MGR" == "yum" ]]; then
    yum install -y jq >/dev/null 2>&1 || true
    if ! command -v jq >/dev/null 2>&1; then
      yum install -y epel-release >/dev/null 2>&1 || true
      yum install -y jq >/dev/null 2>&1 || true
    fi
  fi

  # Fallback cuối: tải jq binary trực tiếp nếu package manager vẫn fail
  if ! command -v jq >/dev/null 2>&1; then
    warn "Package manager chưa cài được jq — thử tải jq binary trực tiếp..."
    ARCH_RAW="$(uname -m)"
    case "$ARCH_RAW" in
      x86_64|amd64) JQ_URL="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64" ;;
      aarch64|arm64) JQ_URL="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-arm64" ;;
      *) JQ_URL="" ;;
    esac
    if [[ -n "$JQ_URL" ]]; then
      curl -fsSL "$JQ_URL" -o /usr/local/bin/jq >/dev/null 2>&1 || true
      chmod +x /usr/local/bin/jq >/dev/null 2>&1 || true
    fi
  fi

  command -v jq >/dev/null 2>&1 && ok "jq: đã cài" || { err "Không cài được jq"; exit 1; }
else
  ok "jq: có"
fi

# 2.2 Cài Node.js nếu chưa có hoặc version thấp
NEED_NODE=0
if command -v node >/dev/null 2>&1; then
  NODE_MAJOR=$(node -e "console.log(process.versions.node.split('.')[0])" 2>/dev/null || echo "0")
  if [[ "$NODE_MAJOR" -lt "$NODE_VERSION" ]]; then
    warn "Node.js hiện tại: v$(node --version | tr -d v) — cần v${NODE_VERSION}+ để OpenClaw hoạt động tốt"
    NEED_NODE=1
  else
    ok "Node.js: v$(node --version | tr -d v)"
  fi
else
  info "Node.js chưa được cài — sẽ cài tự động"
  NEED_NODE=1
fi

if [[ "$NEED_NODE" -eq 1 ]]; then
  info "Cài Node.js v${NODE_VERSION} LTS..."
  if [[ "$PKG_MGR" == "apt" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash - >/dev/null 2>&1 || true
    apt-get install -y nodejs >/dev/null 2>&1 || true
  elif [[ "$PKG_MGR" == "yum" ]]; then
    curl -fsSL "https://rpm.nodesource.com/setup_${NODE_VERSION}.x" | bash - >/dev/null 2>&1 || true
    yum install -y nodejs >/dev/null 2>&1 || true
  fi

  # Fallback cuối: tải Node.js binary trực tiếp nếu package manager vẫn fail
  if ! command -v node >/dev/null 2>&1; then
    warn "Package manager chưa cài được Node.js — thử tải Node.js binary trực tiếp..."
    ARCH_RAW="$(uname -m)"
    case "$ARCH_RAW" in
      x86_64|amd64) NODE_ARCH="x64" ;;
      aarch64|arm64) NODE_ARCH="arm64" ;;
      *) NODE_ARCH="" ;;
    esac
    if [[ -n "$NODE_ARCH" ]]; then
      NODE_TARBALL="node-v${NODE_VERSION}.17.1-linux-${NODE_ARCH}.tar.xz"
      NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}.17.1/${NODE_TARBALL}"
      TMP_DIR="$(mktemp -d)"
      if curl -fsSL "$NODE_URL" -o "$TMP_DIR/$NODE_TARBALL" >/dev/null 2>&1; then
        tar -xJf "$TMP_DIR/$NODE_TARBALL" -C "$TMP_DIR" >/dev/null 2>&1 || true
        mkdir -p /usr/local/lib/nodejs >/dev/null 2>&1 || true
        rm -rf "/usr/local/lib/nodejs/node-v${NODE_VERSION}.17.1-linux-${NODE_ARCH}" >/dev/null 2>&1 || true
        cp -a "$TMP_DIR/node-v${NODE_VERSION}.17.1-linux-${NODE_ARCH}" /usr/local/lib/nodejs/ 2>/dev/null || true
        ln -sf "/usr/local/lib/nodejs/node-v${NODE_VERSION}.17.1-linux-${NODE_ARCH}/bin/node" /usr/local/bin/node
        ln -sf "/usr/local/lib/nodejs/node-v${NODE_VERSION}.17.1-linux-${NODE_ARCH}/bin/npm" /usr/local/bin/npm
        ln -sf "/usr/local/lib/nodejs/node-v${NODE_VERSION}.17.1-linux-${NODE_ARCH}/bin/npx" /usr/local/bin/npx
        chmod +x /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx 2>/dev/null || true
      fi
      rm -rf "$TMP_DIR" >/dev/null 2>&1 || true
    fi
  fi

  command -v node >/dev/null 2>&1 && ok "Node.js: v$(node --version | tr -d v)" || { err "Không cài được Node.js"; exit 1; }
fi

# 2.3 Kiểm tra npm
if ! command -v npm >/dev/null 2>&1; then
  info "npm chưa có — cài riêng..."
  if [[ "$PKG_MGR" == "apt" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y npm >/dev/null 2>&1 || true
  elif [[ "$PKG_MGR" == "yum" ]]; then
    yum install -y npm >/dev/null 2>&1 || true
  fi
  command -v npm >/dev/null 2>&1 && ok "npm: v$(npm --version)" || { err "Không cài được npm"; exit 1; }
else
  ok "npm: v$(npm --version)"
fi

# 2.3b Kiểm tra git (npm có thể cần khi resolve dependency)
if ! command -v git >/dev/null 2>&1; then
  info "git chưa có — cài tự động..."
  if [[ "$PKG_MGR" == "apt" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y git >/dev/null 2>&1 || true
    if ! command -v git >/dev/null 2>&1; then
      timeout 90 apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=1 -o Acquire::http::Timeout=20 update -qq >/dev/null 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y git >/dev/null 2>&1 || true
    fi
  elif [[ "$PKG_MGR" == "yum" ]]; then
    yum install -y git >/dev/null 2>&1 || true
  fi
  command -v git >/dev/null 2>&1 && ok "git: $(git --version | head -1)" || { err "Không cài được git"; exit 1; }
else
  ok "git: $(git --version | head -1)"
fi

ensure_openclaw_bin() {
  if command -v openclaw >/dev/null 2>&1; then
    return 0
  fi

  local candidate=""
  local npm_root=""
  npm_root="$(npm root -g 2>/dev/null || true)"

  for p in \
    /usr/lib/node_modules/openclaw/openclaw.mjs \
    /usr/local/lib/node_modules/openclaw/openclaw.mjs \
    "$npm_root/openclaw/openclaw.mjs"
  do
    if [[ -n "$p" && -f "$p" ]]; then
      candidate="$p"
      break
    fi
  done

  if [[ -n "$candidate" ]]; then
    ln -sf "$candidate" /usr/local/bin/openclaw
    chmod +x /usr/local/bin/openclaw 2>/dev/null || true
  fi

  command -v openclaw >/dev/null 2>&1
}

install_openclaw() {
  npm install -g openclaw@latest --loglevel=error 2>&1 | grep -v "^npm warn" || true
  ensure_openclaw_bin || true
  # Nếu lỗi ENOTEMPTY hoặc binary chưa lên — xóa và cài lại
  if ! openclaw --version >/dev/null 2>&1; then
    warn "Cài lần đầu thất bại — thử xóa thư mục cũ và cài lại..."
    rm -rf /usr/lib/node_modules/openclaw /usr/local/lib/node_modules/openclaw 2>/dev/null || true
    npm install -g openclaw@latest --loglevel=error 2>&1 | grep -v "^npm warn" || true
    ensure_openclaw_bin || true
  fi
}

fetch_provider_models() {
  local resp=""
  local parsed=""

  resp="$(curl -fsSL --max-time 20 \
    -H "Authorization: Bearer ${API_KEY_FIXED}" \
    -H "Content-Type: application/json" \
    "${BASE_URL}/models" 2>/dev/null || true)"

  if [[ -n "$resp" ]]; then
    parsed="$(printf '%s' "$resp" | jq -c '
      if (.data | type) == "array" then
        [.data[]
          | select((.id // "") != "")
          | { id: .id, name: (.id // .name // "") }
        ]
        | unique_by(.id)
      else
        []
      end
    ' 2>/dev/null || true)"
  fi

  if [[ -n "$parsed" && "$parsed" != "[]" ]]; then
    info "Models: lấy từ API ${BASE_URL}/models"
    echo "$parsed"
    return 0
  fi

  warn "Không lấy được models từ API — dùng danh sách mặc định"
  echo "$DEFAULT_MODELS_JSON"
}

build_agent_models_json() {
  local models_json="$1"
  printf '%s' "$models_json" | jq -c '
    reduce .[] as $m ({}; .[("h2cloud/" + $m.id)] = {})
  ' 2>/dev/null || echo '{}'
}

choose_primary_model() {
  local models_json="$1"
  local picked=""
  picked="$(printf '%s' "$models_json" | jq -r --arg want "$MODEL_ID" '
    if any(.[]; .id == $want) then
      $want
    elif ((. // []) | length) > 0 then
      .[0].id
    else
      $want
    end
  ' 2>/dev/null || true)"

  [[ -n "$picked" && "$picked" != "null" ]] || picked="$MODEL_ID"
  echo "$picked"
}

# 2.4 Cài / update OpenClaw
if [[ "$ALREADY_INSTALLED" -eq 1 ]]; then
  # Hỏi có muốn update không (skip khi chạy non-interactive qua pipe)
  DO_UPDATE="yes"
  LATEST_VER="$(npm view openclaw version 2>/dev/null || echo '')"
  INSTALLED_SEMVER="$(printf '%s' "$INSTALLED_VER" | sed -n 's/.*\([0-9]\{4\}\.[0-9]\{1,2\}\.[0-9]\{1,2\}\).*/\1/p' | head -1)"

  if [[ -n "$LATEST_VER" && -n "$INSTALLED_SEMVER" && "$LATEST_VER" == "$INSTALLED_SEMVER" ]]; then
    info "OpenClaw đã là bản mới nhất: $INSTALLED_VER"
    DO_UPDATE="no"
  elif [[ -t 0 ]]; then
    if [[ -n "$LATEST_VER" ]]; then
      echo "OpenClaw hiện tại: $INSTALLED_VER"
      echo "Bản mới nhất trên npm: $LATEST_VER"
      read -r -p "Update lên phiên bản mới nhất? [Y/n]: " ans
    else
      read -r -p "OpenClaw $INSTALLED_VER đã cài. Update lên phiên bản mới nhất? [Y/n]: " ans
    fi
    case "${ans:-Y}" in n|N|no|NO) DO_UPDATE="no" ;; esac
  fi
  if [[ "$DO_UPDATE" == "yes" ]]; then
    info "Update OpenClaw lên phiên bản mới nhất..."
    install_openclaw
  else
    info "Giữ nguyên OpenClaw $INSTALLED_VER"
  fi
else
  info "Cài OpenClaw..."
  install_openclaw
fi

NEW_VER="$(openclaw --version 2>/dev/null | head -1 || echo 'unknown')"
ok "OpenClaw: $NEW_VER"

# 2.5 Init config nếu chưa có
if [[ ! -f "$OPENCLAW_CONFIG" ]]; then
  info "Khởi tạo config OpenClaw lần đầu..."
  mkdir -p "$(dirname "$OPENCLAW_CONFIG")"
  openclaw init --non-interactive >/dev/null 2>&1 || true
  sleep 2
  # Fallback: tạo config tối thiểu nếu init vẫn không tạo file
  if [[ ! -f "$OPENCLAW_CONFIG" ]]; then
    warn "openclaw init không tạo được config — tạo config tối thiểu..."
    cat > "$OPENCLAW_CONFIG" << 'MINCFG'
{
  "models": { "providers": {} },
  "agents": { "defaults": { "model": { "primary": "" }, "models": {} } },
  "channels": { "telegram": {} },
  "plugins": { "entries": { "telegram": { "enabled": false } } }
}
MINCFG
  fi
fi
ok "Config: $OPENCLAW_CONFIG"

# 2.6 Setup systemd service — tự tạo file, dùng `openclaw gateway` (foreground)
# KHÔNG dùng `openclaw gateway start` (chạy service manager, fail khi thiếu D-Bus)
# KHÔNG dùng `openclaw gateway install` (overwrite config)
SERVICE_FILE="/etc/systemd/system/openclaw-gateway.service"
ensure_openclaw_bin || true
OPENCLAW_BIN="$(command -v openclaw || true)"
if [[ -z "$OPENCLAW_BIN" ]]; then
  err "Không tìm thấy binary openclaw"
  exit 1
fi
if systemctl is-active --quiet openclaw-gateway 2>/dev/null; then
  ok "Service openclaw-gateway: đang chạy"
else
  info "Tạo systemd service..."
  cat > "$SERVICE_FILE" << EOF
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
User=root
ExecStart=$OPENCLAW_BIN gateway
Restart=always
RestartSec=5
StandardInput=null

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable openclaw-gateway >/dev/null 2>&1 || true
  ok "Service openclaw-gateway: đã tạo và enable"
fi

echo ""

# ─────────────────────────────────────────────────
# GIAI ĐOẠN 3: SETUP CONFIG + KÍCH HOẠT KEY H2CLOUD
# ─────────────────────────────────────────────────
echo -e "${CYAN}▶ Giai đoạn 3/3: Setup config + kích hoạt key H2Cloud${NC}"
echo ""

# 3.1 Thu thập Telegram bot token
BOT_TOKEN="${BOT_TOKEN:-}"
TG_IDS_RAW="${TG_ALLOW_FROM:-}"

EXISTING_BOT_TOKEN="$(jq -r '.channels.telegram.botToken // ""' "$OPENCLAW_CONFIG" 2>/dev/null || echo "")"
EXISTING_ALLOW_RAW="$(jq -r '(.channels.telegram.allowFrom // []) | join(",")' "$OPENCLAW_CONFIG" 2>/dev/null || echo "")"
EXISTING_ALLOW_COUNT="$(jq -r '(.channels.telegram.allowFrom // []) | length' "$OPENCLAW_CONFIG" 2>/dev/null || echo "0")"

UPDATE_TELEGRAM="yes"
TELEGRAM_READY=0

# Xác định trạng thái hiện tại
if [[ -n "$EXISTING_BOT_TOKEN" && "$EXISTING_ALLOW_COUNT" -gt 0 ]]; then
  TELEGRAM_READY=1
fi

if [[ "$TELEGRAM_READY" -eq 1 ]]; then
  # Đã có đầy đủ → hỏi có muốn đổi không
  info "Telegram đã cấu hình sẵn (token: ...${EXISTING_BOT_TOKEN: -8}, ${EXISTING_ALLOW_COUNT} ID)"
  if [[ -z "$BOT_TOKEN" && -z "$TG_IDS_RAW" ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Cập nhật Telegram mới không? [y/N]: " ans
      case "${ans:-N}" in y|Y|yes|YES) UPDATE_TELEGRAM="yes" ;; *) UPDATE_TELEGRAM="no" ;; esac
    else
      UPDATE_TELEGRAM="no"  # non-interactive pipe: giữ nguyên nếu đã có
    fi
  fi
else
  # Chưa có → bắt buộc phải nhập, không cho bỏ qua
  UPDATE_TELEGRAM="yes"
  if [[ -z "$BOT_TOKEN" && -z "$TG_IDS_RAW" ]]; then
    if [[ ! -t 0 ]]; then
      err "Chạy qua pipe nhưng chưa có Telegram config. Cần truyền biến môi trường:"
      err "  BOT_TOKEN=xxx TG_ALLOW_FROM=\"id1,id2\" bash <(curl -fsSL ...)"
      exit 1
    fi
  fi
fi

if [[ "$UPDATE_TELEGRAM" == "yes" ]]; then
  # Bot token
  if [[ -z "$BOT_TOKEN" ]]; then
    while true; do
      read -r -p "Telegram bot token (từ @BotFather, vd 123456789:ABC...): " BOT_TOKEN
      [[ -n "$BOT_TOKEN" ]] && break
      err "Bot token không được để trống"
    done
  fi

  # Hiện thông tin bot để verify token đúng
  BOT_ME_JSON="$(curl -fsSL --max-time 15 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null || true)"
  BOT_OK="$(printf '%s' "$BOT_ME_JSON" | jq -r '.ok // false' 2>/dev/null || echo false)"
  if [[ "$BOT_OK" == "true" ]]; then
    BOT_USERNAME="$(printf '%s' "$BOT_ME_JSON" | jq -r '.result.username // empty' 2>/dev/null || true)"
    BOT_FIRST_NAME="$(printf '%s' "$BOT_ME_JSON" | jq -r '.result.first_name // empty' 2>/dev/null || true)"
    if [[ -n "$BOT_USERNAME" ]]; then
      ok "Bot Telegram: ${BOT_FIRST_NAME} (@${BOT_USERNAME})"
      info "Link bot: https://t.me/${BOT_USERNAME}"
    else
      ok "Bot Telegram hợp lệ: ${BOT_FIRST_NAME}"
    fi
  else
    warn "Không lấy được thông tin bot từ token (có thể token sai hoặc mạng Telegram lỗi)"
  fi

  # Telegram IDs
  if [[ -z "$TG_IDS_RAW" ]]; then
    while true; do
      read -r -p "Telegram user IDs allowlist (phân cách bằng dấu phẩy, vd: 5201295658,6028278329): " TG_IDS_RAW
      [[ -n "$TG_IDS_RAW" ]] && break
      err "Danh sách Telegram ID không được để trống"
    done
  fi
fi

# Parse allowFrom JSON array
ALLOW_JSON="[]"
if [[ "$UPDATE_TELEGRAM" == "yes" ]]; then
  ALLOW_JSON="$(echo "$TG_IDS_RAW" | awk -F',' '
    BEGIN { printf("[") }
    { c=0; for(i=1;i<=NF;i++) { gsub(/^ +| +$/,"",$i); if(length($i)>0) { if(c>0)printf(","); printf("\"%s\"",$i); c++ } } }
    END { printf("]") }
  ')"
  [[ "$ALLOW_JSON" == "[]" ]] && { err "Không parse được Telegram IDs"; exit 1; }
fi

# 3.2 Backup + patch config
BACKUP_PATH="${OPENCLAW_CONFIG}.bk-$(date +%Y%m%d-%H%M%S)"
cp -a "$OPENCLAW_CONFIG" "$BACKUP_PATH"
ok "Backup config: $BACKUP_PATH"

PROVIDER_MODELS_JSON="$(fetch_provider_models)"
AGENT_MODELS_JSON="$(build_agent_models_json "$PROVIDER_MODELS_JSON")"
PRIMARY_MODEL_ID="$(choose_primary_model "$PROVIDER_MODELS_JSON")"
PRIMARY_MODEL_FULL="$PROVIDER_NAME/$PRIMARY_MODEL_ID"
info "Model mặc định sẽ dùng: $PRIMARY_MODEL_FULL"

TMP_FILE="$(mktemp)"

if [[ "$UPDATE_TELEGRAM" == "yes" ]]; then
  jq \
    --arg provider "$PROVIDER_NAME" \
    --arg baseUrl "$BASE_URL" \
    --arg apiKey "$API_KEY_FIXED" \
    --arg primaryModel "$PRIMARY_MODEL_FULL" \
    --arg botToken "$BOT_TOKEN" \
    --argjson providerModels "$PROVIDER_MODELS_JSON" \
    --argjson agentModels "$AGENT_MODELS_JSON" \
    --argjson allowFrom "$ALLOW_JSON" \
  '
    .models.providers[$provider] = {
      baseUrl: $baseUrl,
      apiKey: $apiKey,
      api: "openai-completions",
      models: $providerModels
    }
    | .agents.defaults.model.primary = $primaryModel
    | .agents.defaults.models = $agentModels
    | .channels.telegram = ((.channels.telegram // {}) + {
        name: (.channels.telegram.name // "Telegram Bot"),
        enabled: true,
        dmPolicy: "allowlist",
        groupPolicy: "allowlist",
        botToken: $botToken,
        allowFrom: $allowFrom
      })
    | .plugins.entries.telegram.enabled = true
    | .gateway = ((.gateway // {}) + { mode: "local" })
  ' "$OPENCLAW_CONFIG" > "$TMP_FILE"
else
  # Chỉ patch provider + model, giữ nguyên Telegram
  jq \
    --arg provider "$PROVIDER_NAME" \
    --arg baseUrl "$BASE_URL" \
    --arg apiKey "$API_KEY_FIXED" \
    --arg primaryModel "$PRIMARY_MODEL_FULL" \
    --argjson providerModels "$PROVIDER_MODELS_JSON" \
    --argjson agentModels "$AGENT_MODELS_JSON" \
  '
    .models.providers[$provider] = {
      baseUrl: $baseUrl,
      apiKey: $apiKey,
      api: "openai-completions",
      models: $providerModels
    }
    | .agents.defaults.model.primary = $primaryModel
    | .agents.defaults.models = $agentModels
    | .plugins.entries.telegram.enabled = true
    | .gateway = ((.gateway // {}) + { mode: "local" })
  ' "$OPENCLAW_CONFIG" > "$TMP_FILE"
  info "Giữ nguyên Telegram hiện có (skip update)"
fi

mv "$TMP_FILE" "$OPENCLAW_CONFIG"
ok "Đã patch config H2Cloud provider"

# 3.3 Khởi động / restart service (với auto-fix thiếu deps)
start_gateway() {
  if systemctl is-active --quiet openclaw-gateway 2>/dev/null; then
    systemctl restart openclaw-gateway
  else
    systemctl start openclaw-gateway
  fi
  sleep 3
  systemctl is-active --quiet openclaw-gateway
}

info "Khởi động openclaw-gateway..."
# Sửa ExecStart nếu vẫn dùng `gateway start` (lỗi D-Bus) — đổi sang `gateway` (foreground)
if [[ -f "$SERVICE_FILE" ]]; then
  OPENCLAW_BIN="$(command -v openclaw || true)"
  if [[ -z "$OPENCLAW_BIN" && -f "/usr/lib/node_modules/openclaw/openclaw.mjs" ]]; then
    ln -sf /usr/lib/node_modules/openclaw/openclaw.mjs /usr/local/bin/openclaw
    chmod +x /usr/local/bin/openclaw || true
    OPENCLAW_BIN="/usr/local/bin/openclaw"
  fi
  if grep -q 'gateway start' "$SERVICE_FILE"; then
    sed -i "s|^ExecStart=.*|ExecStart=$OPENCLAW_BIN gateway --allow-unconfigured|" "$SERVICE_FILE"
    systemctl daemon-reload
    warn "Sửa ExecStart: gateway start → gateway --allow-unconfigured (fix lỗi D-Bus)"
  elif ! grep -q -- '--allow-unconfigured' "$SERVICE_FILE"; then
    sed -i "s|^ExecStart=.*|ExecStart=$OPENCLAW_BIN gateway --allow-unconfigured|" "$SERVICE_FILE"
    systemctl daemon-reload
    warn "Bổ sung --allow-unconfigured vào ExecStart"
  fi
fi
if start_gateway; then
  ok "Service openclaw-gateway: đang chạy"
else
  # Kiểm tra log xem có lỗi thiếu deps không
  JOURNAL_LOG="$(journalctl -u openclaw-gateway -n 20 --no-pager 2>/dev/null || true)"
  if echo "$JOURNAL_LOG" | grep -q "Cannot find package\|MODULE_NOT_FOUND\|ERR_MODULE_NOT_FOUND"; then
    warn "Phát hiện lỗi thiếu dependencies — reinstall OpenClaw để fix..."
    npm install -g openclaw@latest --loglevel=error 2>&1 | grep -v "^npm warn" || true
    NEW_VER="$(openclaw --version 2>/dev/null | head -1 || echo 'unknown')"
    ok "Reinstall xong: $NEW_VER"
    # Cập nhật đường dẫn binary trong service nếu cần
    OPENCLAW_BIN="$(command -v openclaw || true)"
    if [[ -z "$OPENCLAW_BIN" && -f "/usr/lib/node_modules/openclaw/openclaw.mjs" ]]; then
      ln -sf /usr/lib/node_modules/openclaw/openclaw.mjs /usr/local/bin/openclaw
      chmod +x /usr/local/bin/openclaw || true
      OPENCLAW_BIN="/usr/local/bin/openclaw"
    fi
    sed -i "s|^ExecStart=.*|ExecStart=$OPENCLAW_BIN gateway --allow-unconfigured|" "$SERVICE_FILE"
    systemctl daemon-reload
    if start_gateway; then
      ok "Service openclaw-gateway: đang chạy (sau reinstall)"
    else
      err "Service vẫn chưa active sau reinstall. Log:"
      journalctl -u openclaw-gateway -n 15 --no-pager 2>/dev/null || true
      exit 1
    fi
  else
    err "Service chưa active. Log:"
    echo "$JOURNAL_LOG"
    exit 1
  fi
fi

# 3.4 Verify config cơ bản
if jq -e --arg p "$PROVIDER_NAME" --arg pm "$PRIMARY_MODEL_FULL" '
  .models.providers[$p].baseUrl != null and
  .models.providers[$p].apiKey != null and
  .agents.defaults.model.primary == $pm
' "$OPENCLAW_CONFIG" >/dev/null 2>&1; then
  ok "Verify config: hợp lệ"
else
  warn "Verify config: có thể có vấn đề — kiểm tra thủ công tại $OPENCLAW_CONFIG"
fi

GATEWAY_STATUS_OUTPUT="$(openclaw gateway status 2>/dev/null || true)"
GATEWAY_DASHBOARD="$(printf '%s\n' "$GATEWAY_STATUS_OUTPUT" | sed -n 's/^Dashboard: //p' | head -1)"
GATEWAY_BIND_LINE="$(printf '%s\n' "$GATEWAY_STATUS_OUTPUT" | sed -n 's/^Gateway: //p' | head -1)"
GATEWAY_LISTENING="$(printf '%s\n' "$GATEWAY_STATUS_OUTPUT" | sed -n 's/^Listening: //p' | head -1)"

# ─────────────────────────────────────────────────
# KẾT QUẢ
# ─────────────────────────────────────────────────
echo ""
echo "============================================="
echo -e "${GREEN}             CÀI ĐẶT HOÀN TẤT!${NC}"
echo "============================================="
echo ""
ok "OpenClaw: $NEW_VER"
ok "Provider: $PROVIDER_NAME (ưu tiên models từ API ${BASE_URL}/models)"
ok "Model mặc định: $PRIMARY_MODEL_FULL"
if [[ "$UPDATE_TELEGRAM" == "yes" ]]; then
  ok "Telegram IDs: $TG_IDS_RAW"
else
  ok "Telegram: giữ nguyên cấu hình cũ (${EXISTING_ALLOW_COUNT} ID)"
fi
ok "Backup config: $BACKUP_PATH"
ok "Log: $LOG_FILE"
if [[ -n "$GATEWAY_BIND_LINE" ]]; then
  ok "Gateway: $GATEWAY_BIND_LINE"
fi
if [[ -n "$GATEWAY_LISTENING" ]]; then
  ok "Listening: $GATEWAY_LISTENING"
fi
if [[ -n "$GATEWAY_DASHBOARD" ]]; then
  ok "Dashboard: $GATEWAY_DASHBOARD"
fi
echo ""
info "Kiểm tra trạng thái:"
echo "  systemctl status openclaw-gateway"
echo "  openclaw status"
echo "  openclaw status --all"
echo "  openclaw gateway probe"
echo "  openclaw gateway status"
echo "  openclaw doctor"
echo "  openclaw channels status --probe"
echo "  openclaw logs --follow"
echo ""
