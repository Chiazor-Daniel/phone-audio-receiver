#Requires -Version 5.1
<#
.SYNOPSIS
    Phone Audio Receiver for Windows (A2DP Sink)
.DESCRIPTION
    Pure PowerShell controller to receive Bluetooth audio from iPhone/Android on Windows 10/11.
    Supports multi-device simultaneous audio streaming using WinRT AudioPlaybackConnection.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("start", "stop", "status", "install", "uninstall", "list")]
    [string]$Action = "start",

    [string]$DeviceName = $env:COMPUTERNAME,
    [switch]$Startup,
    [switch]$Interactive,
    [switch]$DryRun,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
$PS_EXE   = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$TASK     = "PhoneAudioReceiver"
$SHIM_DIR = Join-Path $env:LOCALAPPDATA "PhoneAudioReceiver"
$INSTALLED_SCRIPT = Join-Path $SHIM_DIR "Receiver.ps1"

# Re-launch under Windows PowerShell 5.1 if invoked from PowerShell 7 (pwsh)
if ($PSVersionTable.PSEdition -ne "Desktop" -and (Test-Path $PS_EXE)) {
    $fwd = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", $Action)
    if ($Startup) { $fwd += "-Startup" }
    if ($Interactive) { $fwd += "-Interactive" }
    if ($DryRun) { $fwd += "-DryRun" }
    if ($DeviceName -and $DeviceName -ne $env:COMPUTERNAME) { $fwd += @("-DeviceName", "`"$DeviceName`"") }
    & $PS_EXE $fwd
    exit $LASTEXITCODE
}

if ($Help) {
    Write-Host @"
Phone Audio Receiver (Windows)
Turn your PC into a Bluetooth receiver for iPhone and Android audio.

Usage:
  par [action] [options]

Actions:
  start        Start audio streaming in background (default)
  stop         Stop background streaming and release Bluetooth
  status       Show receiver and background task status
  list         List currently connected Bluetooth audio devices
  install      One-time setup (services, driver fixes, global 'par' command)
  uninstall    Remove startup task, 'par' command, and settings

Options:
  -Interactive  Run in foreground with live logs (with start)
  -Startup      Enable automatic startup on Windows logon (with install)
  -DeviceName   Target phone by name filter
  -DryRun       Preview changes without modifying system
  -Help         Show this help message

Examples:
  par start                Start receiving audio (background)
  par start -Interactive   Start in foreground with live output
  par stop                 Stop all audio streaming
  par list                 Show connected Bluetooth audio devices
  par install -Startup     Install + auto-start on logon
"@
    exit 0
}

# ── Helpers ──

function Log($msg, $color = "White") {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg" -ForegroundColor $color
}

function Set-Reg($path, $name, $val, $type = "DWord") {
    if (-not (Test-Path $path)) { New-Item $path -Force | Out-Null }
    Set-ItemProperty $path -Name $name -Value $val -Type $type -Force -ErrorAction SilentlyContinue
}

function Assert-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin -and -not $DryRun) {
        Write-Host "-> Administrator privileges required for '$Action'. Elevating..." -ForegroundColor Yellow
        $fwd = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $Action" + $(if ($Startup) { " -Startup" }) + $(if ($DeviceName -and $DeviceName -ne $env:COMPUTERNAME) { " -DeviceName `"$DeviceName`"" })
        Start-Process $PS_EXE -ArgumentList $fwd -Verb RunAs -Wait
        exit 0
    }
}

function Init-WinRT {
    [void][Windows.Media.Audio.AudioPlaybackConnection, Windows.Media, ContentType=WindowsRuntime]
    [void][Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType=WindowsRuntime]
    [void][Windows.Devices.Bluetooth.BluetoothDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    if (-not $script:asTask) {
        $script:asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq "AsTask" -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1
        } | Select-Object -First 1
    }
}

function Await-WinRT($op, [Type]$type) {
    $t = $script:asTask.MakeGenericMethod($type).Invoke($null, @($op))
    if ($t.Wait(10000)) { return $t.Result }
}

function Connect-Audio($conn) {
    try {
        $conn.Start()
        return Await-WinRT ($conn.OpenAsync()) ([Windows.Media.Audio.AudioPlaybackConnectionOpenResult])
    } catch { return $null }
}

function Get-ConnectedAudioDevices {
    Init-WinRT
    $all = Await-WinRT ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync([Windows.Media.Audio.AudioPlaybackConnection]::GetDeviceSelector())) ([Windows.Devices.Enumeration.DeviceInformationCollection])
    if (-not $all) { return @() }
    @($all | Where-Object {
        try {
            $bt = Await-WinRT ([Windows.Devices.Bluetooth.BluetoothDevice]::FromIdAsync($_.Id)) ([Windows.Devices.Bluetooth.BluetoothDevice])
            -not $bt -or $bt.ConnectionStatus -eq "Connected"
        } catch { $true }
    })
}

function Get-ReceiverProcesses {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "Receiver\.ps1.*(start|\-Interactive)" -and $_.ProcessId -ne $PID }
}

function Optimize-BluetoothAudio {
    Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue | Where-Object Status -eq "OK" | ForEach-Object {
        $reg = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.InstanceId)\Device Parameters"
        if (Test-Path $reg) { Set-ItemProperty $reg SelectiveSuspendEnabled 0 -Type DWord -ErrorAction SilentlyContinue }
    }
    Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Services\USB\DisableSelectiveSuspend" "DisableSelectiveSuspend" 1
    powercfg /SETACVALUEINDEX SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>$null
    powercfg /SETACTIVE SCHEME_CURRENT 2>$null
}

# ── Actions ──

switch ($Action) {
    "install" {
        Assert-Admin
        Write-Host "-> Installing Phone Audio Receiver on Windows..." -ForegroundColor Cyan

        if ([Environment]::OSVersion.Version.Build -lt 19041) {
            Write-Error "Unsupported Windows build. Windows 10 build 19041+ or Windows 11 required."
            exit 1
        }

        if ($DryRun) {
            Write-Host "   (dry) Configure services, power settings, registry stability, 'par' command"
        } else {
            Set-Service bthserv -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service bthserv -ErrorAction SilentlyContinue
            Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters" "SystemRemoteWakeSupported" 1
            Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\238C7A80-46D4-4192-B707-0C9BF773BA46" "Attributes" 2
            Optimize-BluetoothAudio
            Write-Host "++ Bluetooth service and audio optimizations applied." -ForegroundColor Green

            if (-not (Test-Path $SHIM_DIR)) { New-Item $SHIM_DIR -ItemType Directory -Force | Out-Null }
            Copy-Item $PSCommandPath $INSTALLED_SCRIPT -Force
            Set-Content (Join-Path $SHIM_DIR "par.cmd") "@echo off`r`n`"$PS_EXE`" -NoProfile -ExecutionPolicy Bypass -File `"$INSTALLED_SCRIPT`" %*" -Force
            Write-Host "++ Created 'par' command." -ForegroundColor Green

            $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
            if ($userPath -notlike "*$SHIM_DIR*") {
                [Environment]::SetEnvironmentVariable("Path", "$userPath;$SHIM_DIR", "User")
                $env:Path = "$env:Path;$SHIM_DIR"
                Write-Host "++ Added to PATH." -ForegroundColor Green
            }
        }

        if ($Startup) {
            if ($DryRun) {
                Write-Host "   (dry) Register-ScheduledTask -TaskName '$TASK'"
            } else {
                $act = New-ScheduledTaskAction -Execute $PS_EXE -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$INSTALLED_SCRIPT`" start"
                $trg = New-ScheduledTaskTrigger -AtLogOn
                $prn = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
                $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
                Register-ScheduledTask -TaskName $TASK -Action $act -Trigger $trg -Principal $prn -Settings $set -Force | Out-Null
                Write-Host "++ Scheduled task '$TASK' enabled (runs on logon)." -ForegroundColor Green
            }
        }

        Write-Host "`nSetup Complete!`nOpen a NEW terminal, then use:`n  par start    Start receiving audio`n  par stop     Stop receiving audio`n  par list     Show connected devices`n" -ForegroundColor Green
    }

    "list" {
        $devices = Get-ConnectedAudioDevices
        Write-Host "Connected Bluetooth Audio Devices ($($devices.Count) found):" -ForegroundColor Cyan
        if ($devices.Count) {
            $devices | ForEach-Object { Write-Host "  - $($_.Name)" -ForegroundColor White }
        } else {
            Write-Host "  No connected devices. Make sure your phone's Bluetooth is ON and paired."
        }
    }

    "start" {
        if (-not $Interactive) {
            $procs = Get-ReceiverProcesses
            if ($procs) {
                Write-Host "!! Receiver is already running (PID: $($procs[0].ProcessId)). Use 'par stop' first." -ForegroundColor Yellow
                exit 0
            }
            $bgArgs = "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" start -Interactive"
            if ($DeviceName -and $DeviceName -ne $env:COMPUTERNAME) { $bgArgs += " -DeviceName `"$DeviceName`"" }
            $p = Start-Process $PS_EXE -ArgumentList $bgArgs -PassThru -WindowStyle Hidden
            Write-Host "++ Receiver started in background (PID: $($p.Id)).`n   Use 'par stop' to stop  |  'par status' to check" -ForegroundColor Green
            exit 0
        }

        Write-Host "=== Phone Audio Receiver (Windows A2DP Sink) ===`nMulti-device mode. Press Ctrl+C to stop.`n" -ForegroundColor Cyan
        Init-WinRT
        $connections = @{}
        $scanTick = 0

        try {
            while ($true) {
                $scanTick++
                if ($connections.Count -eq 0 -or $scanTick % 5 -eq 0) {
                    $devices = Get-ConnectedAudioDevices
                    $targets = if ($DeviceName -and $DeviceName -ne $env:COMPUTERNAME) { @($devices | Where-Object Name -like "*$DeviceName*") } else { @($devices) }

                    if ($targets.Count -eq 0 -and $connections.Count -eq 0) {
                        Log "Waiting for phone(s)... (Bluetooth ON + paired)"
                        Start-Sleep -Seconds 4
                        continue
                    }

                    foreach ($dev in $targets) {
                        if (-not $connections.ContainsKey($dev.Id)) {
                            $conn = [Windows.Media.Audio.AudioPlaybackConnection]::TryCreateFromId($dev.Id)
                            if ($conn) {
                                $res = Connect-Audio $conn
                                $st = if ($res) { $res.Status } else { "Timeout" }
                                if ($st -eq "Success") { Log "Connected: '$($dev.Name)' -> PC speakers" Green }
                                else { Log "'$($dev.Name)': $st" Yellow }

                                $connections[$dev.Id] = @{ Conn = $conn; Name = $dev.Name; LastState = $null; ClosedTicks = 0 }
                                Start-Sleep -Milliseconds 500
                            }
                        }
                    }
                }

                $toRemove = @()
                foreach ($id in @($connections.Keys)) {
                    $entry = $connections[$id]
                    try { $state = $entry.Conn.State } catch { $toRemove += $id; continue }

                    if ($state -eq "Opened") {
                        $entry.ClosedTicks = 0
                        if ($entry.LastState -ne "Opened") {
                            $entry.LastState = "Opened"
                            Log "Streaming: '$($entry.Name)'" Green
                        }
                    } elseif ($state -eq "Closed") {
                        $entry.ClosedTicks++
                        if ($entry.ClosedTicks -eq 1) {
                            Log "'$($entry.Name)' dropped, recovering..." Yellow
                            $res = Connect-Audio $entry.Conn
                            if ($res -and $res.Status -eq "Success") {
                                $entry.ClosedTicks = 0
                                $entry.LastState = "Opened"
                                Log "'$($entry.Name)' recovered." Green
                            }
                        }
                        if ($entry.ClosedTicks -ge 3) {
                            Log "'$($entry.Name)' disconnected." Yellow
                            $toRemove += $id
                        }
                        $entry.LastState = $state
                    } else {
                        $entry.LastState = $state
                    }
                }

                foreach ($id in $toRemove) {
                    try { $connections[$id].Conn.Dispose() } catch {}
                    $connections.Remove($id)
                }

                if ($scanTick % 10 -eq 0 -and $connections.Count -gt 0) {
                    Log "Active ($($connections.Count)): $(($connections.Values | ForEach-Object Name) -join ', ')" DarkCyan
                }
                Start-Sleep -Seconds 3
            }
        } finally {
            $connections.Values | ForEach-Object { try { $_.Conn.Dispose() } catch {} }
            Write-Host "`nReceiver stopped. All devices released." -ForegroundColor Yellow
        }
    }

    "stop" {
        try {
            $t = Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
            if ($t -and $t.State -eq "Running") { Stop-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue }
        } catch {}

        $procs = Get-ReceiverProcesses
        if ($procs) {
            $procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Write-Host "++ Receiver stopped." -ForegroundColor Green
        } else {
            Write-Host "!! Receiver was not running." -ForegroundColor Yellow
        }
    }

    "status" {
        $procs = Get-ReceiverProcesses
        Write-Host ("Receiver:     " + $(if ($procs) { "RUNNING (PID: $($procs[0].ProcessId))" } else { "NOT RUNNING" })) -ForegroundColor $(if ($procs) { "Green" } else { "Yellow" })
        try {
            $t = Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
            Write-Host "Startup Task: $(if ($t) { $t.State } else { 'Not Registered' })"
        } catch {}
        try {
            $devices = Get-ConnectedAudioDevices
            if ($devices.Count) {
                Write-Host "Connected:    $($devices.Count) device(s)" -ForegroundColor Cyan
                $devices | ForEach-Object { Write-Host "              - $($_.Name)" }
            } else {
                Write-Host "Connected:    No devices"
            }
        } catch {}
    }

    "uninstall" {
        Assert-Admin
        Write-Host "-> Uninstalling Phone Audio Receiver..." -ForegroundColor Cyan
        Get-ReceiverProcesses | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        try { Unregister-ScheduledTask -TaskName $TASK -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch {}
        if (Test-Path $SHIM_DIR) { Remove-Item $SHIM_DIR -Recurse -Force -ErrorAction SilentlyContinue }
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($userPath -like "*$SHIM_DIR*") {
            $newPath = ($userPath -split ";" | Where-Object { $_ -and $_ -ne $SHIM_DIR }) -join ";"
            [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        }
        Write-Host "++ Uninstall complete." -ForegroundColor Green
    }
}
