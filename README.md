# phone-audio-receiver

Turn any PC (Windows or Linux) into a high-quality **Bluetooth audio receiver**, so all audio from your iPhone (or Android) plays seamlessly through your computer's speakers or headset. Supports **multiple devices streaming at the same time**. Pair your phone, press play.

This project also includes battle-tested fixes for the dreaded **MediaTek / Filogic (MT7921 / RZ608) A2DP disconnect and stutter bug** on both Windows and Linux.

---

## Choose Your Platform

- **[Windows (PowerShell)](#windows-powershell)**
- **[Linux (Bash)](#linux-bash)**

---

## Windows (PowerShell)

Built natively for **Windows 10 (Version 2004 / Build 19041+)** and **Windows 11** using Windows Runtime (`Windows.Media.Audio.AudioPlaybackConnection`) and PowerShell. Supports **simultaneous multi-device audio streaming**.

### Windows Quick Start

1. Run the one-time setup (in PowerShell as Administrator):

   - **From the project folder:**

     ```powershell
     .\windows\Receiver.ps1 install
     ```

     *(Be sure to include the `.\` prefix)*

   - **From ANY folder or path:**

     ```powershell
     & "$HOME\Desktop\Projects\phone-audio-receiver\windows\Receiver.ps1" install
     ```

   *Configures Bluetooth services, applies driver stability and audio quality fixes, installs the script standalone to `%LOCALAPPDATA%\PhoneAudioReceiver`, and creates the global `par` command.*

2. Open a **new terminal** and start streaming:

   ```powershell
   par start
   ```

3. On your **iPhone or Android**, go to **Settings → Bluetooth**, tap your PC's name, and pair.
4. Press play on your phone! All audio now streams through your PC speakers.
5. Connect **additional phones** — they all stream simultaneously.

> **Tip:** `par start` runs in the background and survives closing the terminal. Use `par stop` when you're done.

---

### The `par` Command

After running `install`, the `par` command is available **globally from any directory** — no need to navigate to the project folder.

| Goal | Command |
| --- | --- |
| **Start streaming (background)** | `par start` |
| **Start streaming (foreground with live output)** | `par start -Interactive` |
| **Stop streaming** | `par stop` |
| **Check receiver status** | `par status` |
| **List currently connected Bluetooth audio devices** | `par list` |
| **Enable automatic start on PC boot** | `par install -Startup` |
| **Uninstall and clean up** | `par uninstall` |

> You can also call the script directly with `.\windows\Receiver.ps1 [action]` if you prefer.

---

### Multi-Device Streaming

The receiver automatically connects to **all Bluetooth audio devices** that are currently paired and in range. Multiple phones can stream audio to your PC at the same time.

- Only **actively connected** devices are tracked — previously paired devices that are out of range or powered off are ignored.
- If a device disconnects, the receiver automatically attempts recovery before dropping it.
- New devices are discovered every ~15 seconds without disrupting active streams.

---

### The Windows MediaTek (MT7921) Stability Fix

On Windows, combo Wi-Fi 6/Bluetooth cards (like the MediaTek MT7921, Filogic 3300, and AMD RZ608) often suffer from aggressive USB/PCIe **Selective Suspend**. Windows puts the Bluetooth radio into a low-power sleep state during brief playback pauses, resulting in audio stutter or dropping the connection with the phone.

`par install` applies:

- **Registry stability parameters** (located in [`windows/configs/MediaTek-Windows-Fix.reg`](windows/configs/MediaTek-Windows-Fix.reg)) to keep the Bluetooth radio awake.
- **USB Selective Suspend disable** on all Bluetooth adapters to prevent audio crackling.
- **Bluetooth power plan optimization** for high-performance audio.

---

### Calls & Microphone on Windows

When your phone is paired to Windows over Bluetooth, call audio and microphone routing can be handled in two ways:

1. **Windows Phone Link (Link to Windows)**: The recommended Microsoft experience. Allows answering phone calls directly on your PC using your PC's microphone and speakers.
2. **Bluetooth Handsfree Telephony**: In Windows Control Panel (*Devices and Printers* → Your Phone → *Properties* → *Services* tab), ensure **Handsfree Telephony** is checked if you want Windows to expose headset call endpoints.

---

### Windows Troubleshooting

- **Phone is paired but audio doesn't play**:
  Run `par start` to open the audio stream. Windows does not auto-route Bluetooth audio without an active receiver connection.
- **Audio crackling or stutter**:
  Ensure you ran `par install` (as Administrator) to apply the power management and selective suspend fixes.
- **`par` command not found**:
  Open a **new terminal** after running `install`. The command is added to your user PATH during installation.
- **Only one device plays audio**:
  Make sure all devices are paired and their Bluetooth is on. Run `par list` to verify which devices are detected. The receiver connects to all available devices automatically.
- **Wrong output speakers**:
  Windows routes incoming audio to your system's default audio output device. Check **Settings → System → Sound** to ensure your preferred speakers or headset are set as default.
- **Uninstalling**:

  ```powershell
  par uninstall
  ```

---

## Linux (Bash)

Supports Fedora/Nobara, Ubuntu/Debian, Arch, and openSUSE with PipeWire/WirePlumber or PulseAudio.

### Linux Quick Start

```bash
sudo ./linux/install.sh --name "Living Room"
```

Installs/enables BlueZ, applies the PipeWire A2DP stability fix, assigns a friendly adapter name, and configures the audio sink.

#### Options

| Flag | Meaning |
| --- | --- |
| `--name "My PC"` | Friendly name phones see when pairing (default: hostname) |
| `--dry-run` | Show every action without changing anything |
| `-h`, `--help` | Help |

---

### The Linux MediaTek (MT7921) Fix

On MT7921/Filogic cards, upstream BlueZ hands A2DP playback off to the card's DSP, which misreports stream completion and causes BlueZ to disconnect. The fix forces software decoding, disables hardware volume pass-through for stability, and stops profile autoswitching.

The configuration file is installed to `/etc/wireplumber/wireplumber.conf.d/51-bluetooth-fix.conf` (source: [`linux/configs/51-bluetooth-fix.conf`](linux/configs/51-bluetooth-fix.conf)):

```ini
monitor.bluez.properties = {
  bluez5.hw-offload-datapath = false
  bluez5.enable-hw-volume = false
  bluez5.enable-hfphsp = true
  bluez5.roles = [ a2dp_sink hfp_hf ]
}
wireplumber.settings = {
  bluetooth.autoswitch-to-headset-profile = false
}
```

---

### Calls & Microphone on Linux (AirPods-Style Mic)

The PC exposes both `a2dp_sink` (for high-fidelity stereo music) and `hfp_hf` (Hands-Free unit for phone calls). During phone calls, your PC's microphone acts as the phone's microphone, and the caller's voice plays through your PC speakers.

---

### Linux Uninstall

```bash
sudo rm -f /etc/wireplumber/wireplumber.conf.d/51-bluetooth-fix.conf
sudo systemctl --user restart wireplumber pipewire
sudo systemctl disable --now bluetooth   # only if not needed otherwise
sudo bluetoothctl system-alias ""        # reset adapter name
```

---

## License

[MIT](LICENSE)