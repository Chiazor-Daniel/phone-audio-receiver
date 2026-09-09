#!/usr/bin/env bash
set -euo pipefail

PROG="$(basename "$0")"
DEVICE_NAME="$(hostname -s 2>/dev/null || hostname)"
DRY_RUN=0

usage() {
  cat <<EOF
$PROG - turn this Linux box into a Bluetooth receiver for phone audio.

Your iPhone or Android pairs to the PC over Bluetooth, and all its audio
plays through the PC's speakers or headset. This is the reliable path:
no Wi-Fi, no AirPlay, no firewall games.

Options:
  --name NAME        Friendly name phones see when pairing (default: hostname)
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
  arch|manjaro|endeavouros) PKG_MGR="pacman" ;;
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

bt_receiver_setup() {
  log "Installing the Bluetooth stack"
  pkg_install bluez || warn "bluez install failed; Bluetooth may not work"

  if command -v wireplumber >/dev/null 2>&1; then
    log "Applying the BlueZ stability fix for PipeWire/WirePlumber"
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
    log "Applying the Bluetooth fix for PulseAudio"
    pkg_install pulseaudio-module-bluetooth || pkg_install pulseaudio-modules-bt \
      || warn "Install a pulseaudio bluetooth module for your distro"
    run pactl unload-module module-bluetooth-discover 2>/dev/null || true
    run pactl load-module module-bluetooth-discover
  else
    warn "Neither PipeWire nor PulseAudio detected; install one for audio to work."
  fi

  log "Enabling the Bluetooth service"
  run systemctl enable --now bluetooth || warn "bluetooth service not found"

  log "Giving the controller a friendly name: $DEVICE_NAME"
  run bluetoothctl system-alias "$DEVICE_NAME" || warn "could not set the adapter name"
}

summary() {
  cat <<EOF

Done. This machine is now a Bluetooth audio receiver named "$DEVICE_NAME".

iPhone:  Settings -> Bluetooth -> tap "$DEVICE_NAME" to pair, then play.
         Audio from every app routes to this PC's output.
Android: Settings -> Bluetooth -> tap "$DEVICE_NAME" -> Pair, then play.

If it ever pairs but disconnects the moment you press play, the fix is
already installed at:
  /etc/wireplumber/wireplumber.conf.d/51-bluetooth-fix.conf

Check with:  wpctl status     (PipeWire) / pactl list sinks (PulseAudio)
See README.md for troubleshooting.
EOF
}

log "phone-audio-receiver (bluetooth) on $DISTRO_ID (package manager: ${PKG_MGR:-none})"
[[ -n "$PKG_MGR" ]] || warn "'$DISTRO_ID' is not in the supported list; continue at your own risk."

bt_receiver_setup
summary