#!/usr/bin/env bash
set -euo pipefail

PROG="$(basename "$0")"
DEVICE_NAME="$(hostname -s 2>/dev/null || hostname)"
ENABLE_AIRPLAY=1
ENABLE_MIRROR=0
WIFI_FIX=1
DRY_RUN=0

usage() {
  cat <<EOF
$PROG - turn this Linux box into a receiver for phone audio (iPhone/Android).

Options:
  --name NAME        Friendly name shown on your phone (default: hostname)
  --no-airplay       Skip the AirPlay receiver (shairport-sync)
  --mirror           Also install UxPlay for iPhone screen mirroring, where packaged
  --no-wifi-fix      Do not disable Wi-Fi power save
  --dry-run          Print what would happen without changing anything
  -h, --help         Show this help

Run as root (the script will re-invoke itself with sudo if needed).
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) DEVICE_NAME="$2"; shift 2 ;;
    --name=*) DEVICE_NAME="${1#*=}"; shift ;;
    --no-airplay) ENABLE_AIRPLAY=0; shift ;;
    --mirror) ENABLE_MIRROR=1; shift ;;
    --no-wifi-fix) WIFI_FIX=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
done

log() { printf '\033[1;34m->\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '   (dry) %s\n' "$*"
    return 0
  fi
  "$@"
}

if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E -H bash "$0" "$@"
  else
    echo "Please run as root." >&2
    exit 1
  fi
fi

DISTRO_ID="unknown"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-unknown}"
fi

PKG_MGR=""
case "$DISTRO_ID" in
  fedora|nobara|rhel|centos) PKG_MGR="dnf" ;;
  ubuntu|debian|linuxmint|pop|linuxlite) PKG_MGR="apt" ;;
  arch|manjaro|endeavouros|archcraft) PKG_MGR="pacman" ;;
  opensuse*|suse) PKG_MGR="zypper" ;;
esac

pkg_install() {
  case "$PKG_MGR" in
    dnf)    run dnf install -y "$@" ;;
    apt)    run apt-get update -qq || true; run apt-get install -y "$@" ;;
    pacman) run pacman -S --noconfirm --needed "$@" ;;
    zypper) run zypper install -y "$@" ;;
    *)
      warn "Unsupported distro ($DISTRO_ID). Install manually: $*"
      return 1
      ;;
  esac
}

airplay_setup() {
  log "Installing shairport-sync (AirPlay audio receiver)"
  pkg_install shairport-sync || warn "shairport-sync install failed; AirPlay will be skipped"

  local backend="alsa"
  if command -v wireplumber >/dev/null 2>&1 || command -v wpctl >/dev/null 2>&1; then
    backend="pw"
  elif command -v pactl >/dev/null 2>&1; then
    backend="pa"
  fi

  if command -v shairport-sync >/dev/null 2>&1 || [[ $DRY_RUN -eq 1 ]]; then
    if [[ -f /etc/shairport-sync.conf && ! -f /etc/shairport-sync.conf.phone-audio.bak ]]; then
      run cp /etc/shairport-sync.conf /etc/shairport-sync.conf.phone-audio.bak
    fi
    run tee /etc/shairport-sync.conf >/dev/null <<EOF
general = {
  name = "$DEVICE_NAME";
  output_backend = "$backend";
};
EOF
    run systemctl enable --now shairport-sync || warn "could not start shairport-sync"
  fi
}

mirror_setup() {
  [[ $ENABLE_MIRROR -eq 1 ]] || return 0
  log "Installing UxPlay (iPhone screen mirroring)"
  case "$PKG_MGR" in
    dnf)
      run dnf copr enable -y fdh2/uxplay && run dnf install -y uxplay \
        || warn "UxPlay is not available on $DISTRO_ID via dnf"
      ;;
    *)
      warn "UxPlay is not packaged for $DISTRO_ID. See README.md for building from source."
      ;;
  esac
}

firewall_setup() {
  log "Opening AirPlay ports on the firewall"
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    run firewall-cmd --permanent --add-service=mdns
    run firewall-cmd --permanent --add-port=5000/tcp
    run firewall-cmd --permanent --add-port=6000-6010/udp
    run firewall-cmd --permanent --add-port=7000/tcp
    run firewall-cmd --permanent --add-port=7000/udp
    run firewall-cmd --reload
  elif command -v ufw >/dev/null 2>&1; then
    run ufw allow 5353/udp
    run ufw allow 5000/tcp
    run ufw allow 6000:6010/udp
    run ufw allow 7000/tcp
    run ufw allow 7000/udp
  else
    warn "No firewalld or ufw found. Open 5000/tcp, 6000-6010/udp, 5353/udp manually."
  fi
}

service_setup() {
  log "Enabling avahi (mDNS discovery) and bluetooth services"
  run systemctl enable --now avahi-daemon || warn "avahi-daemon not found"
  run systemctl enable --now bluetooth || warn "bluetooth service not found"
}

bluetooth_receiver_setup() {
  log "Configuring Bluetooth as a phone-audio receiver"
  if command -v wireplumber >/dev/null 2>&1; then
    local wpl_dir="/etc/wireplumber/wireplumber.conf.d"
    run mkdir -p "$wpl_dir"
    run tee "$wpl_dir/51-bluetooth-fix.conf" >/dev/null <<'CONF'
# phone-audio-receiver: BlueZ A2DP stability fixes (helps MediaTek/Filogic cards)
monitor.bluez.properties = {
  bluez5.hw-offload-datapath = false
  bluez5.enable-hw-volume = false
}
wireplumber.settings = {
  bluetooth.autoswitch-to-headset-profile = false
}
CONF
    run systemctl --user restart wireplumber pipewire || true
  elif command -v pactl >/dev/null 2>&1; then
    pkg_install pulseaudio-module-bluetooth || pkg_install pulseaudio-modules-bt \
      || warn "Install a pulseaudio bluetooth module for your distro"
    run pactl unload-module module-bluetooth-discover 2>/dev/null || true
    run pactl load-module module-bluetooth-discover
  else
    warn "Neither PipeWire nor PulseAudio detected; Bluetooth receive may not work."
  fi
}

wifi_setup() {
  [[ $WIFI_FIX -eq 1 ]] || return 0
  log "Disabling Wi-Fi power save (helps audio latency and dropouts)"
  if ! command -v iw >/dev/null 2>&1 && [[ $DRY_RUN -eq 0 ]]; then
    pkg_install iw || warn "install the 'iw' tool to toggle power save"
  fi
  for entry in /sys/class/net/*/wireless; do
    [[ -d "$entry" ]] || continue
    local dev
    dev="$(basename "$(dirname "$entry")")"
    if command -v iw >/dev/null 2>&1; then
      run iw dev "$dev" set power_save off
    fi
  done
}

summary() {
  cat <<EOF

Done. This machine is now a phone-audio receiver named "$DEVICE_NAME".

iPhone (AirPlay): Control Center -> long-press the volume slider -> tap the
  AirPlay icon -> select "$DEVICE_NAME".

iPhone or Android (Bluetooth): Settings -> Bluetooth -> connect to
  "$DEVICE_NAME", then play anything. Audio lands on this machine's output.

Check status with:
  systemctl status shairport-sync
  wpctl status            (PipeWire) / pactl list sinks (PulseAudio)

See README.md for troubleshooting and uninstall instructions.
EOF
}

log "phone-audio-receiver on $DISTRO_ID (package manager: ${PKG_MGR:-none})"
[[ -n "$PKG_MGR" ]] || warn "'$DISTRO_ID' is not in the supported list; continue at your own risk."

[[ $ENABLE_AIRPLAY -eq 1 ]] && airplay_setup
mirror_setup
firewall_setup
service_setup
bluetooth_receiver_setup
wifi_setup
summary