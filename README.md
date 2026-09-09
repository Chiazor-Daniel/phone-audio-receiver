# phone-audio-receiver

Turn any Linux desktop or server into a **phone audio receiver**, so all audio
from your iPhone (or Android phone) plays through your PC's speakers or headset
in about a minute.

This is the battle-tested recipe from a real Fedora/Nobara session that fixed:

- AirPlay audio via **shairport-sync** (PipeWire/pulse as output backend)
- Bluetooth A2DP receive, and the nasty **MediaTek / Filogic (MT7921) A2DP
  disconnect bug** — where a phone pairs fine but drops mid-playback (`Missing
  completion reports for packet`, BlueZ `NotAuthorized` errors)
- Wi-Fi power-save stutter and firewall/mDNS blocks that make AirPlay
  receivers invisible to iPhones

## Quick start

```bash
sudo ./install.sh --name "Bedroom"
```

The script detects your distro and does everything: installs the receivers,
applies the MediaTek BlueZ fix, opens the firewall, enables mDNS, and turns off
Wi-Fi power save.

### Options

| Flag | Meaning |
| --- | --- |
| `--name "My PC"` | Friendly name phones see (default: hostname) |
| `--no-airplay` | Only Bluetooth receive, skip shairport-sync |
| `--mirror` | Also install UxPlay for iPhone screen mirroring (where packaged) |
| `--no-wifi-fix` | Leave Wi-Fi power save alone |
| `--dry-run` | Show every action without changing anything |
| `-h`, `--help` | Help |

## What it sets up

| Piece | Purpose |
| --- | --- |
| shairport-sync | AirPlay audio receiver for iPhone/iPad/Mac streaming |
| BlueZ + WirePlumber fix | BlueZ A2DP stability fixes in `/etc/wireplumber/wireplumber.conf.d/51-bluetooth-fix.conf` |
| firewalld/ufw ports | mDNS (5353/udp), AirPlay (5000/tcp, 6000-6010/udp, 7000/tcp+udp) |
| avahi-daemon | Lets your phone find the receiver over the network |
| `iw power_save off` | Reduces audio latency and dropouts on Wi-Fi |

## Supported distros

| Distro | Package manager | AirPlay | UxPlay mirror |
| --- | --- | --- | --- |
| Fedora / Nobara / RHEL / CentOS | dnf | yes | yes (via COPR) |
| Ubuntu / Debian / Mint / Pop!_OS | apt | yes | no (build from source) |
| Arch / Manjaro / EndeavourOS | pacman | yes | AUR |
| openSUSE | zypper | yes | no (build from source) |

## How to connect

### iPhone → AirPlay (audio, best quality)

1. Make sure the phone and PC are on the same Wi-Fi network.
2. Control Center → long-press the **volume** slider → tap the **AirPlay** icon.
3. Select your PC's name. Audio now streams to the PC's default output.

### iPhone / Android → Bluetooth

1. On the phone, open Bluetooth settings and pair with the PC's name.
2. Play anything — phone audio plays through the PC's output.

### iPhone → screen mirroring

Required: `--mirror` and UxPlay built/packaged for your distro (Fedora COPR
`fdh2/uxplay`; elsewhere build from
[UxPlay](https://github.com/FDH2/UxPlay)). Then run:

```bash
uxplay -vs 0 -nh -n "My PC" &
```

Video mirrors to your screen and all phone audio follows. Note: default
latency works best; `-al 0.08` (80 ms) is a small reduction if speakers vs
screen sync allows it, but forcing `sync=false/async=false` in the pipeline
causes clock drift stutter (`invalid ntp_time < gst_audio_pipeline_base_time`).

## The MediaTek A2DP bug this fixes

On MT7921/Filogic 3300 Wi-Fi/Bluetooth combo cards, upstream BlueZ hands
A2DP playback off to the card's DSP. The card misreports stream completion,
so BlueZ kills the link and the phone disconnects seconds after you press play
(firmware reports like `Missing completion reports for packet`, followed by
`org.bluez.Error.NotAuthorized`). The fix disables the offload data path and
the automatic A2DP ↔ HFP profile switch that races your audio session:

```ini
monitor.bluez.properties = {
  bluez5.hw-offload-datapath = false
  bluez5.enable-hw-volume = false
}
wireplumber.settings = {
  bluetooth.autoswitch-to-headset-profile = false
}
```

Keep `bluez5.enable-hw-volume = true` if you prefer adjusting volume from the
phone rather than the PC. The same file lives in
[`configs/51-bluetooth-fix.conf`](configs/51-bluetooth-fix.conf) for manual
install.

## Troubleshooting

- **Phone never sees the receiver** → check avahi: `systemctl status avahi-daemon`;
  confirm both devices are on the same network; if a firewall is active, ensure
  mDNS (5353/udp) is open.
- **Stream stutters** → turn Wi-Fi power save off:
  `sudo iw dev wlo1 set power_save off`.
- **Bluetooth pairs but drops when playing** → the MediaTek fix above. After
  editing the config: `systemctl --user restart wireplumber`.
- **AirPlay works but mirroring doesn't** → UxPlay needs ports 7000/7001 open
  and `-nh` (no hardware overlay) for Wayland.

## Uninstall

```bash
sudo rm -f /etc/shairport-sync.conf.phone-audio.bak
sudo shairport-sync -k            # or: sudo systemctl disable --now shairport-sync
sudo rm -f /etc/wireplumber/wireplumber.conf.d/51-bluetooth-fix.conf
sudo systemctl --user restart wireplumber pipewire
sudo firewall-cmd --permanent --remove-port=5000/tcp \
  --remove-port=6000-6010/udp --remove-port=7000/tcp --remove-port=7000/udp
sudo firewall-cmd --reload
```

## License

[MIT](LICENSE)