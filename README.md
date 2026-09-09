# phone-audio-receiver

Turn any Linux desktop or server into a **Bluetooth audio receiver**, so all
audio from your iPhone (or Android) plays through your PC's speakers or
headset. Bluetooth only — nothing to do with Wi-Fi, AirPlay, or the network.

This is the battle-tested recipe from a real Fedora/Nobara session that fixed
the dreaded **MediaTek / Filogic (MT7921) A2DP disconnect bug**, where a phone
pairs fine but drops mid-playback with `Missing completion reports for packet`
and `org.bluez.Error.NotAuthorized` firmware errors.

## Quick start

```bash
sudo ./install.sh --name "Living Room"
```

That's it: installs/enables BlueZ, applies the A2DP stability fix, gives the
adapter a friendly name, and prints pairing instructions.

### Options

| Flag | Meaning |
| --- | --- |
| `--name "My PC"` | Friendly name phones see when pairing (default: hostname) |
| `--dry-run` | Show every action without changing anything |
| `-h`, `--help` | Help |

## What it sets up

| Piece | Purpose |
| --- | --- |
| bluez | The BlueZ Bluetooth stack |
| `/etc/wireplumber/wireplumber.conf.d/51-bluetooth-fix.conf` | The A2DP stability fix (see below) |
| `bluetoothctl system-alias` | Friendly adapter name your phone sees |
| avahi is *not* needed | Bluetooth pairing works with zero network config |

## How to connect

### iPhone

1. **Settings → Bluetooth** and tap your PC's name to pair (enter the
   on-screen code if asked).
2. Play anything. All phone audio — every app — routes to the PC's output.

### Android

1. **Settings → Bluetooth**, tap your PC's name, confirm "Pair".
2. Play anything. Audio lands on the PC's default output.

## The fix this repo exists for

On MT7921/Filogic 3300 Wi-Fi/Bluetooth combo cards, upstream BlueZ hands A2DP
playback off to the card's DSP. The card misreports stream completion, so
BlueZ kills the link and the phone disconnects seconds after you press play
(`Missing completion reports for packet`, then `org.bluez.Error.NotAuthorized`).
Automatic A2DP ↔ HFP profile switching makes it worse, racing your audio
session. The fix forces software decoding, disables phone-side volume
pass-through for stability, and stops the profile switch:

```ini
monitor.bluez.properties = {
  bluez5.hw-offload-datapath = false
  bluez5.enable-hw-volume = false
}
wireplumber.settings = {
  bluetooth.autoswitch-to-headset-profile = false
}
```

Turn `bluez5.enable-hw-volume` back to `true` if you prefer volume control on
your phone. Same file for manual install:
[`configs/51-bluetooth-fix.conf`](configs/51-bluetooth-fix.conf).

## Troubleshooting

- **Pairs but disconnects when playing** → the fix above. After changing it:
  `systemctl --user restart wireplumber`.
- **Phone shows no audio output** → check the sink: `wpctl status`
  (PipeWire) or `pactl list sinks` (PulseAudio).
- **No A2DP option, only phone-call audio** → the profile auto-switch is on;
  your fix file is missing or not being read. Confirm the path matches
  `/etc/wireplumber/wireplumber.conf.d/`.
- **Want reset pairing** → `bluetoothctl remove <phone-mac>` then pair again.

## Supported distros

| Distro | Package manager |
| --- | --- |
| Fedora / Nobara / RHEL / CentOS | dnf |
| Ubuntu / Debian / Mint / Pop!_OS | apt |
| Arch / Manjaro / EndeavourOS | pacman |
| openSUSE | zypper |

## Uninstall

```bash
sudo rm -f /etc/wireplumber/wireplumber.conf.d/51-bluetooth-fix.conf
sudo systemctl --user restart wireplumber pipewire
sudo systemctl disable --now bluetooth   # only if you didn't need it before
sudo bluetoothctl system-alias ""        # reset the adapter name
```

## License

[MIT](LICENSE)