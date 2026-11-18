# FOMOdoro - DailyLogger

*Fear of missing out, meet Pomodoro.*

A small Windows tray app that asks **"What are you working on?"** on a timer and appends your answer to a Markdown file for the day. It's built for quick brain dumps: type a line, hit Enter, get back to work, without opening a note full of everything else you haven't done yet.

Ignore the prompt and it slowly grows until it fills your screen. Hence the name.

It's a single PowerShell script. Nothing to install, no admin rights needed.

## Features

- Prompts every 20 minutes (configurable) from a bottom-right popup
- Scheduled prompts slowly grow to full screen until you answer or skip
- Global hotkey (**Ctrl+Alt+L**) or tray double-click to log anytime
- Checklist items: start a line with `[ ]` and it becomes an Obsidian-style task
- Skips prompts when the screen is locked, you're idle, it's the weekend, or you've paused it
- One Markdown file per day, organized into `yyyy\MM` folders (works well as an Obsidian daily note)
- Runs headless from the tray: no console window, starts at logon

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (built into Windows). PowerShell 7 isn't needed.

## Setup

1. Clone the repo, or download `DailyLogTray.ps1` to a folder you'll keep:

   ```powershell
   git clone https://github.com/NetworkGitsTheBestWork/FOMOdoro---DailyLogger.git
   ```

2. In PowerShell, run the block below with `$script` pointing at your copy. It creates a shortcut in your Startup folder, so the app launches at every logon, and then starts it.

   ```powershell
   $script = "C:\Path\To\FOMOdoro---DailyLogger\DailyLogTray.ps1"
   Unblock-File $script
   $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) "FOMOdoro.lnk"
   $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
   $s.TargetPath = "conhost.exe"
   $s.Arguments  = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`""
   $s.Save()
   Invoke-Item $lnk
   ```

3. On first launch, pick the folder where log files should go.

The shortcut launches through `conhost --headless`, so no console window appears. Don't run the script directly in a PowerShell window for everyday use: the console has to stay open, and closing it or pressing Ctrl+C there stops the app.

## Using it

**When a prompt appears**, type what you're doing:

| Key | Action |
|---|---|
| Enter | Save |
| Shift+Enter | New line |
| Ctrl+T, or the ☐ Task button | Insert a checklist item |
| Esc | Skip |

**To log something anytime:** press **Ctrl+Alt+L**, double-click the tray icon, or choose **Log now** from the tray menu.

**Scheduled prompts** chime, appear in the bottom-right corner, and after a one-minute grace period start growing toward full screen. Growth stops the moment you start typing. A prompt closes itself shortly before the next one is due. Manual entries don't chime or grow, and skipping one writes nothing.

**Prompts are skipped automatically** when:

- the screen is locked (a prompt that's already open closes when you lock),
- you've had no keyboard or mouse input for 15+ minutes (logged as `[AFK]`),
- it's the weekend (configurable), or
- the app is paused.

## Log format

One file per day, `yyyy-MM-dd.md`, in `yyyy\MM` subfolders under your log folder:

```
<LogFolder>\2026\11\2026-11-18.md
```

```markdown
# Daily Log - Wednesday, November 18, 2026

- **09:20** FMC policy cleanup
  waiting on vendor quote
- [ ] **09:40** call back carrier about circuit
- **10:00** change review prep
  - [ ] update diagram
  - [ ] send MOP to team
- **10:20** _[AFK]_
- **10:40** _[skipped]_
```

Start the first line with `[ ]` (or `- [ ]`) to make the whole entry a checkbox. Start any later line that way to make a sub-task. Both render as real checkboxes in Obsidian.

| Marker | Meaning |
|---|---|
| `_[AFK]_` | Idle or screen locked (one marker per stretch away) |
| `_[skipped]_` | You pressed Esc |
| `_[no entry]_` | The prompt timed out with nothing typed |

Anything you typed is saved even if the prompt times out or closes because you locked the screen. Only Esc discards it.

Files are written as UTF-8 without a byte-order mark, so Obsidian properties (frontmatter) work if you add them.

### Keeping the log open while you work

Fine in Obsidian, VS Code, and Notepad++: they pick up new entries automatically. In Notepad++, turn on **Settings → Preferences → MISC → File Status Auto-Detection → Update silently**, or use **View → Monitoring (tail -f)** for a read-only live view.

Avoid plain Notepad. It doesn't reload, so saving from it overwrites entries added since you opened the file.

## Tray menu

Right-click the icon. On Windows 11 it may land in the `^` overflow; drag it onto the taskbar to keep it visible. Hover over it to see when the next prompt is due.

- **Log now** - open a prompt
- **Pause** - 30 min, 1 hr, 2 hr, or until resumed
- **Interval** - 10 to 60 minutes (resets the countdown)
- **Skip weekends**, **Chime on prompt** - toggles
- **Open today's log**, **Open log folder**, **Change log folder...**
- **Edit settings...** - opens the settings file (exit and relaunch to apply)
- **Exit**

## Settings

Stored in `DailyLog.settings.json` next to the script and created on first run. `DailyLog.settings.example.json` shows every setting; you can copy it to `DailyLog.settings.json` and edit it before first launch instead of using the folder picker. Interval, folder, and toggles can be changed from the tray menu; the rest by editing the file. **Exit and relaunch** after editing.

| Setting | Default | Notes |
|---|---|---|
| `LogFolder` | (chosen on first run) | Root folder for log files |
| `SubfolderFormat` | `yyyy\MM` | Subfolders under `LogFolder`. `""` puts every file directly in `LogFolder`. In JSON the backslash is doubled: `"yyyy\\MM"`. |
| `IntervalMinutes` | `20` | Time between prompts |
| `IdleMinutes` | `15` | Idle this long = `[AFK]` instead of a prompt |
| `GrowDelaySec` | `60` | Grace period before a prompt starts growing |
| `GrowMinutes` | `10` | Time to grow to full screen |
| `SkipWeekends` | `true` | |
| `Chime` | `true` | Sound on scheduled prompts |
| `Hotkey` | `Ctrl+Alt+L` | `Ctrl`, `Alt`, `Shift`, `Win` plus one key, e.g. `Ctrl+Shift+J`, `Ctrl+Alt+F9`. `""` disables it. |

If the hotkey is already taken by another app, the startup notification says so. Pick another one.

**Testing the grow effect:** set `GrowDelaySec` to `2` and `GrowMinutes` to `0.5`, relaunch, and wait for a prompt. Set them back afterward.

## Launching from Raycast, Stream Deck, etc.

Launching the app while it's already running opens a prompt instead of starting a second copy. Any launcher that can open a file can trigger a prompt by opening `FOMOdoro.lnk` (type `shell:startup` in Win+R to find it). Expect about a second of delay; the built-in hotkey is instant.

If the running copy has stopped responding, a new launch waits two seconds, ends the stuck one, and takes over. Relaunching the shortcut is the fix for a frozen instance.

## Files

| File | Purpose |
|---|---|
| `DailyLogTray.ps1` | The app |
| `DailyLog.settings.example.json` | Example settings, for reference |
| `DailyLog.settings.json` | Your settings (created on first run) |
| `DailyLog.errors.log` | Errors, since there's no console to show them |
| `DailyLog.pid` | ID of the running instance, used for recovery |

The last three are per-user and shouldn't be committed.

## Troubleshooting

- **Something isn't working:** check `DailyLog.errors.log` first.
- **"Running scripts is disabled":** run `Unblock-File` on the script. If your organization enforces an execution policy, the script may need to be signed or allowed by IT.
- **No tray icon:** check the `^` overflow. To confirm it's running:
  ```powershell
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object CommandLine -like '*DailyLogTray*'
  ```
- **.NET "pipeline has been stopped" error:** the script was run in a console and Ctrl+C was pressed. Close the dialog and relaunch from the shortcut.
- **A brief console flash on launch:** the shortcut isn't using `conhost --headless`. Recreate it with step 2.

## Uninstall

Exit from the tray menu, delete `FOMOdoro.lnk` from `shell:startup`, and delete the script folder. Your log files are untouched.
