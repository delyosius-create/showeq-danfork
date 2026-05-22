#!/usr/bin/env bash
# pi-install.sh — builds and installs showeq-daemon on Raspberry Pi OS (Debian-based).
# Run as a regular user with sudo access:
#   bash pi-install.sh
set -euo pipefail

REPO_URL="https://github.com/delyosius-create/showeq-danfork"
INSTALL_DIR="/usr/local"
SERVICE_NAME="showeq-daemon"
CONFIG_DIR="/etc/showeq-daemon"
BUILD_DIR="$HOME/showeq-daemon-build"

# ── colours ──────────────────────────────────────────────────────────────────
bold=$(tput bold 2>/dev/null || true)
reset=$(tput sgr0 2>/dev/null || true)
info()  { echo "${bold}[INFO]${reset}  $*"; }
warn()  { echo "${bold}[WARN]${reset}  $*"; }
die()   { echo "${bold}[ERROR]${reset} $*" >&2; exit 1; }

# ── sanity checks ─────────────────────────────────────────────────────────────
[[ "$(uname -m)" =~ ^(aarch64|armv7l)$ ]] || \
    warn "Not detected as a Pi (arch=$(uname -m)). Continuing anyway."

if [[ $EUID -eq 0 ]]; then
    die "Run this script as a normal user (with sudo access), not as root."
fi

# ── choose network interface ──────────────────────────────────────────────────
echo
info "Available network interfaces:"
ip -br link show | grep -v '^lo' | awk '{print "  " $1 " " $3}'
echo
read -rp "${bold}Enter the interface to capture on (default: eth0): ${reset}" SEQ_DEVICE
SEQ_DEVICE="${SEQ_DEVICE:-eth0}"

read -rp "${bold}WebSocket listen address:port (default: 0.0.0.0:9090): ${reset}" SEQ_LISTEN
SEQ_LISTEN="${SEQ_LISTEN:-0.0.0.0:9090}"

echo
info "Will capture on: ${SEQ_DEVICE}"
info "Will serve WebSocket on: ${SEQ_LISTEN}"
echo

# ── install build dependencies ────────────────────────────────────────────────
info "Installing build dependencies..."
sudo apt-get update -qq
sudo apt-get install -y \
    git cmake build-essential pkg-config python3 \
    qt6-base-dev libqt6websockets6-dev \
    libpcap-dev libprotobuf-dev protobuf-compiler \
    zlib1g-dev

# Qt6 WebSockets header package name varies slightly across Pi OS versions;
# try the fallback Qt5 stack if Qt6 WebSockets headers are absent.
if ! dpkg -l libqt6websockets6-dev &>/dev/null; then
    warn "Qt6 WebSockets dev package not found — falling back to Qt5."
    sudo apt-get install -y \
        qtbase5-dev libqt5websockets5-dev
    QT_FLAG="-DSEQ_USE_QT5=ON"
else
    QT_FLAG=""
fi

# ── clone repository ──────────────────────────────────────────────────────────
info "Cloning repository into ${BUILD_DIR}..."
if [[ -d "$BUILD_DIR/.git" ]]; then
    info "Repo already present — pulling latest..."
    git -C "$BUILD_DIR" pull --ff-only
else
    git clone --recurse-submodules "$REPO_URL" "$BUILD_DIR"
fi

cd "$BUILD_DIR"
git submodule update --init --recursive

# ── build ─────────────────────────────────────────────────────────────────────
info "Configuring..."
cmake -B build \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    ${QT_FLAG}

info "Building (this takes a few minutes on a Pi)..."
cmake --build build -j"$(nproc)"

# ── install binary + data files ───────────────────────────────────────────────
info "Installing binary and config data..."
sudo cmake --install build

# conf/ files (opcode XML, schema) → PKGDATADIR
sudo install -d "${INSTALL_DIR}/share/showeq-daemon"
sudo install -m 0644 conf/zoneopcodes.xml  "${INSTALL_DIR}/share/showeq-daemon/"
sudo install -m 0644 conf/worldopcodes.xml "${INSTALL_DIR}/share/showeq-daemon/"
sudo install -m 0644 conf/seqdef.xml       "${INSTALL_DIR}/share/showeq-daemon/"

# ── grant pcap capabilities (avoids needing sudo at runtime) ──────────────────
info "Granting cap_net_raw + cap_net_admin to binary..."
sudo setcap cap_net_admin,cap_net_raw=eip "${INSTALL_DIR}/bin/showeq-daemon"

# ── write /etc config ─────────────────────────────────────────────────────────
info "Writing ${CONFIG_DIR}/showeq-daemon.env..."
sudo install -d "$CONFIG_DIR"
sudo tee "${CONFIG_DIR}/showeq-daemon.env" > /dev/null <<ENV
SEQ_DEVICE=${SEQ_DEVICE}
SEQ_LISTEN=${SEQ_LISTEN}
SEQ_EXTRA_ARGS=
ENV

# ── install systemd unit ──────────────────────────────────────────────────────
info "Installing systemd unit..."
sudo install -m 0644 \
    packaging/systemd/showeq-daemon.service \
    /etc/systemd/system/showeq-daemon.service

sudo systemctl daemon-reload
sudo systemctl enable showeq-daemon
sudo systemctl restart showeq-daemon

# ── done ──────────────────────────────────────────────────────────────────────
echo
info "Installation complete."
echo
echo "  Service status:   sudo systemctl status showeq-daemon"
echo "  Live logs:        journalctl -u showeq-daemon -f"
echo "  Config:           ${CONFIG_DIR}/showeq-daemon.env"
echo "  WebSocket:        ws://${SEQ_LISTEN}"
echo
info "If you change SEQ_DEVICE or SEQ_LISTEN, edit ${CONFIG_DIR}/showeq-daemon.env"
info "then run: sudo systemctl restart showeq-daemon"
