# DailyLogTray.ps1 - system tray app that prompts for a work log entry on an interval.
# Version 2.0
#
# Right-click the tray icon for options. Double-click it, or press the hotkey
# (default Ctrl+Alt+L), to log an entry now. Settings are saved to
# DailyLog.settings.json next to this script. See README.md.
 
$ErrorActionPreference = 'Stop'
try { [Console]::TreatControlCAsInput = $true } catch { }   # Ctrl+C in a console can't kill it mid-run
 
# ---- Single instance (runs before anything slow) ---------------------------
# A second launch signals the running copy to open a prompt, then exits.
$created = $false
$script:Mutex   = New-Object System.Threading.Mutex($true, 'Local\DailyLogTray', [ref]$created)
$script:ShowEvt = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\DailyLogTray.Show')
$script:AckEvt  = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\DailyLogTray.Ack')
$PidPath = Join-Path $PSScriptRoot 'DailyLog.pid'
if (-not $created) {
    [void]$script:AckEvt.Reset()
    [void]$script:ShowEvt.Set()
    if ($script:AckEvt.WaitOne(2000)) { return }          # healthy instance answered; it will show the prompt
    # No answer in 2s: the old instance is wedged. Kill it and carry on as the new one.
    try { Stop-Process -Id ([int](Get-Content -LiteralPath $PidPath)) -Force } catch { }
    $script:Mutex.Dispose()
    Start-Sleep -Milliseconds 500
    $script:Mutex = New-Object System.Threading.Mutex($true, 'Local\DailyLogTray', [ref]$created)
    if (-not $created) { return }                          # still held; give up rather than fight
}
[IO.File]::WriteAllText($PidPath, "$PID") 
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
 
public static class Win {
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
    [DllImport("user32.dll")] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] static extern bool SwitchDesktop(IntPtr h);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
 
    public static uint IdleSeconds() {
        var l = new LASTINPUTINFO(); l.cbSize = (uint)Marshal.SizeOf(l);
        GetLastInputInfo(ref l);
        return ((uint)Environment.TickCount - l.dwTime) / 1000;
    }
 
    // Locked (or on the secure desktop) when the input desktop can't be switched to.
    public static bool IsLocked() {
        IntPtr h = OpenInputDesktop(0, false, 0x0100);
        if (h == IntPtr.Zero) return true;
        bool ok = SwitchDesktop(h);
        CloseDesktop(h);
        return !ok;
    }
}
 
// Hidden window that receives a system-wide hotkey.
public class HotkeyWindow : NativeWindow, IDisposable {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    const int WM_HOTKEY = 0x0312;
    const uint MOD_NOREPEAT = 0x4000;
    bool registered;
    public event EventHandler Pressed;
 
    public HotkeyWindow() { CreateHandle(new CreateParams()); }
 
    public bool Register(uint mods, uint vk) {
        if (registered) UnregisterHotKey(Handle, 1);
        registered = RegisterHotKey(Handle, 1, mods | MOD_NOREPEAT, vk);
        return registered;
    }
 
    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY) { var h = Pressed; if (h != null) h(this, EventArgs.Empty); }
        base.WndProc(ref m);
    }
 
    public void Dispose() {
        if (registered) { UnregisterHotKey(Handle, 1); registered = false; }
        DestroyHandle();
    }
}
"@
 
$script:Utf8 = New-Object System.Text.UTF8Encoding $false   # UTF-8 without BOM
 
# ---- Settings --------------------------------------------------------------
$SettingsPath = Join-Path $PSScriptRoot 'DailyLog.settings.json'
$ErrorLogPath = Join-Path $PSScriptRoot 'DailyLog.errors.log'
$Defaults = [ordered]@{
    LogFolder       = ''
    SubfolderFormat = 'yyyy\MM'      # folders under LogFolder; '' = all files directly in LogFolder
    IntervalMinutes = 20
    IdleMinutes     = 15             # no input this long = log [AFK] instead of prompting
    GrowDelaySec    = 60             # grace period before a scheduled prompt starts growing
    GrowMinutes     = 10             # time to grow to full screen
    SkipWeekends    = $true
    Chime           = $true
    Hotkey          = 'Ctrl+Alt+L'   # '' = no hotkey
}
 
function Write-ErrorLog([string]$msg) {
    try { [IO.File]::AppendAllText($ErrorLogPath, "$(Get-Date -Format s)  $msg`r`n", $script:Utf8) } catch { }
}
function Load-Settings {
    $s = [pscustomobject]$Defaults
    if (Test-Path -LiteralPath $SettingsPath) {
        try {
            $saved = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
            foreach ($p in $saved.PSObject.Properties) {
                if ($s.PSObject.Properties[$p.Name]) { $s.($p.Name) = $p.Value }
            }
        } catch { Write-ErrorLog "Settings file unreadable, using defaults: $($_.Exception.Message)" }
    }
    $s
}
function Save-Settings {
    try { [IO.File]::WriteAllText($SettingsPath, ($script:S | ConvertTo-Json), $script:Utf8) }
    catch { Write-ErrorLog "Could not save settings: $($_.Exception.Message)" }
}
function Select-LogFolder {
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose the folder for daily log files'
    if ($script:S.LogFolder -and (Test-Path -LiteralPath $script:S.LogFolder)) { $dlg.SelectedPath = $script:S.LogFolder }
    if ($dlg.ShowDialog() -eq 'OK') { $script:S.LogFolder = $dlg.SelectedPath; Save-Settings; return $true }
    return $false
}
 
$script:S = Load-Settings
if (-not $script:S.LogFolder -or -not (Test-Path -LiteralPath $script:S.LogFolder)) {
    if (-not (Select-LogFolder)) { return }
}
Save-Settings   # writes any newly added settings into the file so they're visible
 
# ---- Log file helpers ------------------------------------------------------
function Get-LogFile([datetime]$d) {
    $dir = $script:S.LogFolder
    if ($script:S.SubfolderFormat) {
        foreach ($seg in ($script:S.SubfolderFormat -split '[\\/]')) {
            if (-not $seg) { continue }
            $fmt = if ($seg.Length -eq 1) { "%$seg" } else { $seg }    # single letters are standard formats otherwise
            $dir = Join-Path $dir $d.ToString($fmt)
        }
    }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $f = Join-Path $dir ($d.ToString('yyyy-MM-dd') + '.md')
    if (-not (Test-Path -LiteralPath $f)) {
        [IO.File]::WriteAllText($f, "# Daily Log - $($d.ToString('dddd, MMMM d, yyyy'))`r`n`r`n", $script:Utf8)
    }
    $f
}
function Test-EndsWithNewline([string]$file) {
    $fs = [IO.File]::Open($file, 'Open', 'Read', 'ReadWrite')
    try {
        if ($fs.Length -eq 0) { return $true }
        [void]$fs.Seek(-1, 'End')
        return ($fs.ReadByte() -eq 10)
    } finally { $fs.Dispose() }
}
function Add-Text([string]$file, [string[]]$lines) {
    $text = ($lines -join "`r`n") + "`r`n"
    for ($i = 0; $i -lt 5; $i++) {
        try {
            # If the file was edited and lost its trailing newline, don't glue onto the last line.
            $prefix = if (Test-EndsWithNewline $file) { '' } else { "`r`n" }
            [IO.File]::AppendAllText($file, $prefix + $text, $script:Utf8)
            return
        } catch { Start-Sleep -Milliseconds 300 }
    }
    Write-ErrorLog "Failed to write to $file : $text"
}
 
$TaskPattern = '^\s*(?:-\s*)?\[( |x|X)\]\s*(.*)$'   # "[ ] x", "- [ ] x", "[x] x"
 
function Format-Entry([datetime]$t, [string[]]$lines) {
    $stamp = "**$($t.ToString('HH:mm'))**"
    $out = @()
    if ($lines[0] -match $TaskPattern) { $out += "- [$($Matches[1])] $stamp $($Matches[2])" }
    else                               { $out += "- $stamp $($lines[0].Trim())" }
    foreach ($l in ($lines | Select-Object -Skip 1)) {
        if ($l -match '^\s*$') { continue }
        if ($l -match $TaskPattern) { $out += "  - [$($Matches[1])] $($Matches[2])" }
        else                        { $out += "  $($l.Trim())" }
    }
    $out
}
function Write-Entry([datetime]$t, [string]$text) {
    Add-Text (Get-LogFile $t) (Format-Entry $t ($text -split "\r?\n"))
}
function Write-Marker([datetime]$t, [string]$marker) {
    Add-Text (Get-LogFile $t) "- **$($t.ToString('HH:mm'))** $marker"
}
function Write-AfkMarker([datetime]$t) {
    $f = Get-LogFile $t
    $last = Get-Content -LiteralPath $f -Tail 1 -Encoding UTF8
    if ($last -notmatch '\[AFK\]') { Write-Marker $t '_[AFK]_' }   # one marker per stretch away
}
 
# ---- Hotkey parsing --------------------------------------------------------
function ConvertTo-Hotkey([string]$s) {
    if (-not $s) { return $null }
    $mods = 0; $vk = 0
    foreach ($part in ($s -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        switch -Regex ($part) {
            '^(ctrl|control)$' { $mods = $mods -bor 2; continue }
            '^alt$'            { $mods = $mods -bor 1; continue }
            '^shift$'          { $mods = $mods -bor 4; continue }
            '^win$'            { $mods = $mods -bor 8; continue }
            default {
                $name = if ($part -match '^\d$') { "D$part" } else { $part }
                try { $vk = [int][Windows.Forms.Keys]$name } catch { return $null }
            }
        }
    }
    if (-not $vk -or -not $mods) { return $null }
    @{ Mods = [uint32]$mods; Vk = [uint32]$vk }
}
 
# ---- State -----------------------------------------------------------------
$script:NextDue     = (Get-Date).AddMinutes($script:S.IntervalMinutes)
$script:PausedUntil = $null
$script:P           = $null      # the open prompt, if any
 
# ---- Prompt window ---------------------------------------------------------
$C = @{
    Bg     = [Drawing.Color]::FromArgb(30, 30, 34)
    Field  = [Drawing.Color]::FromArgb(44, 44, 50)
    Text   = [Drawing.Color]::FromArgb(232, 232, 237)
    Muted  = [Drawing.Color]::FromArgb(140, 140, 152)
    Accent = [Drawing.Color]::FromArgb(88, 140, 255)
}
 
function Insert-Task {
    $tb = $script:P.Tb
    $pos = $tb.SelectionStart
    $atLineStart = ($pos -eq 0) -or ($tb.Text[$pos - 1] -eq "`n")
    $tb.SelectedText = if ($atLineStart) { '- [ ] ' } else { "`r`n- [ ] " }
    $tb.Select()
}
 
function Show-Prompt([bool]$Manual) {
    if ($script:P) { $script:P.Form.Activate(); $script:P.Tb.Select(); return }
 
    $wa = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
 
    $form = New-Object Windows.Forms.Form
    $form.FormBorderStyle = 'None'
    $form.StartPosition   = 'Manual'
    $form.Size            = New-Object Drawing.Size(460, 196)
    $form.Location        = New-Object Drawing.Point(($wa.Right - 480), ($wa.Bottom - 216))
    $form.BackColor       = $C.Bg
    $form.TopMost         = $true
    $form.ShowInTaskbar   = $false
    $form.KeyPreview      = $true
    $form.Tag             = 'skip'
 
    $bar = New-Object Windows.Forms.Panel
    $bar.Dock = 'Top'; $bar.Height = 3; $bar.BackColor = $C.Accent
 
    $title = New-Object Windows.Forms.Label
    $title.Text = if ($Manual) { 'Log an entry' } else { 'What are you working on?' }
    $title.Font = New-Object Drawing.Font('Segoe UI Semibold', 11)
    $title.ForeColor = $C.Text
    $title.AutoSize = $true
    $title.Location = New-Object Drawing.Point(18, 18)
 
    $time = New-Object Windows.Forms.Label
    $time.Text = (Get-Date).ToString('HH:mm')
    $time.Font = New-Object Drawing.Font('Segoe UI', 10)
    $time.ForeColor = $C.Muted
    $time.AutoSize = $true
    $time.Location = New-Object Drawing.Point(400, 20)
    $time.Anchor = 'Top,Right'
 
    $fieldWrap = New-Object Windows.Forms.Panel
    $fieldWrap.Location  = New-Object Drawing.Point(18, 52)
    $fieldWrap.Size      = New-Object Drawing.Size(424, 80)
    $fieldWrap.BackColor = $C.Field
    $fieldWrap.Padding   = New-Object Windows.Forms.Padding(10, 8, 10, 8)
    $fieldWrap.Anchor    = 'Top,Bottom,Left,Right'
 
    $tb = New-Object Windows.Forms.TextBox
    $tb.Multiline   = $true
    $tb.BorderStyle = 'None'
    $tb.BackColor   = $C.Field
    $tb.ForeColor   = $C.Text
    $tb.Font        = New-Object Drawing.Font('Segoe UI', 10.5)
    $tb.Dock        = 'Fill'
    $fieldWrap.Controls.Add($tb)
 
    $hint = New-Object Windows.Forms.Label
    $dot = [char]0x00B7
    $hint.Text = "Enter save  $dot  Shift+Enter new line  $dot  Esc skip"
    $hint.Font = New-Object Drawing.Font('Segoe UI', 8.5)
    $hint.ForeColor = $C.Muted
    $hint.AutoSize = $true
    $hint.Location = New-Object Drawing.Point(18, 152)
    $hint.Anchor = 'Bottom,Left'
 
    $taskBtn = New-Object Windows.Forms.Button
    $taskBtn.Text = "$([char]0x2610) Task"
    $taskBtn.FlatStyle = 'Flat'
    $taskBtn.FlatAppearance.BorderSize = 0
    $taskBtn.BackColor = $C.Field
    $taskBtn.ForeColor = $C.Text
    $taskBtn.Font = New-Object Drawing.Font('Segoe UI', 9)
    $taskBtn.Size = New-Object Drawing.Size(72, 30)
    $taskBtn.Location = New-Object Drawing.Point(282, 146)
    $taskBtn.Cursor = 'Hand'
    $taskBtn.TabStop = $false
    $taskBtn.Anchor = 'Bottom,Right'
 
    $btn = New-Object Windows.Forms.Button
    $btn.Text = 'Save'
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 0
    $btn.BackColor = $C.Accent
    $btn.ForeColor = [Drawing.Color]::White
    $btn.Font = New-Object Drawing.Font('Segoe UI Semibold', 9.5)
    $btn.Size = New-Object Drawing.Size(80, 30)
    $btn.Location = New-Object Drawing.Point(362, 146)
    $btn.Cursor = 'Hand'
    $btn.Anchor = 'Bottom,Right'
 
    $form.Controls.AddRange(@($bar, $title, $time, $fieldWrap, $hint, $taskBtn, $btn))
 
    $grow = New-Object Windows.Forms.Timer
    $grow.Interval = 40
    $expire = New-Object Windows.Forms.Timer
    $expire.Interval = [Math]::Max(1, [int]$script:S.IntervalMinutes - 1) * 60000
 
    # Handlers only touch $script:P so they work after this function returns.
    $script:P = @{
        Form = $form; Tb = $tb; Grow = $grow; Expire = $expire
        Opened = Get-Date; Manual = $Manual; WA = $wa; StartSize = $form.Size
        Sw = [Diagnostics.Stopwatch]::StartNew()
    }
 
    $btn.Add_Click({ $script:P.Form.Tag = 'save'; $script:P.Form.Close() })
    $taskBtn.Add_Click({ Insert-Task })
 
    $form.Add_KeyDown({
        if ($_.KeyCode -eq 'Enter' -and -not $_.Shift)  { $_.SuppressKeyPress = $true; $this.Tag = 'save'; $this.Close() }
        elseif ($_.KeyCode -eq 'Escape')                { $this.Tag = 'skip'; $this.Close() }
        elseif ($_.Control -and $_.KeyCode -eq 'T')     { $_.SuppressKeyPress = $true; Insert-Task }
    })
 
    $form.Add_Shown({
        $this.Activate()
        $script:P.Tb.Select()
        if (-not $script:P.Manual -and $script:S.Chime) { [System.Media.SystemSounds]::Asterisk.Play() }
    })
 
    $grow.Add_Tick({
        $p = $script:P
        if (-not $p) { return }
        if ($p.Tb.TextLength -gt 0) { $p.Grow.Stop(); return }      # stop growing once you start typing
        $prog = ($p.Sw.Elapsed.TotalSeconds - $script:S.GrowDelaySec) / ($script:S.GrowMinutes * 60)
        if ($prog -le 0) { return }
        if ($prog -gt 1) { $prog = 1 }
        $e = $prog * $prog                                           # ease-in
        $maxW = $p.WA.Width - 40; $maxH = $p.WA.Height - 40
        $w = [int]($p.StartSize.Width  + ($maxW - $p.StartSize.Width)  * $e)
        $h = [int]($p.StartSize.Height + ($maxH - $p.StartSize.Height) * $e)
        $p.Form.SetBounds($p.WA.Right - 20 - $w, $p.WA.Bottom - 20 - $h, $w, $h)
    })
 
    $expire.Add_Tick({
        $script:P.Expire.Stop()
        $script:P.Form.Tag = 'timeout'
        $script:P.Form.Close()
    })
 
    $form.Add_FormClosed({
        $p = $script:P
        $script:P = $null
        try {
            $p.Grow.Stop(); $p.Expire.Stop()
            $text = $p.Tb.Text.Trim()
            if ($text -and $p.Form.Tag -ne 'skip') {
                Write-Entry $p.Opened $text                  # typed text is kept on save, timeout or lock
            } elseif (-not $p.Manual) {
                switch ($p.Form.Tag) {
                    'timeout' { Write-Marker $p.Opened '_[no entry]_' }
                    'afk'     { Write-AfkMarker $p.Opened }
                    default   { Write-Marker $p.Opened '_[skipped]_' }
                }
            }
            $p.Grow.Dispose(); $p.Expire.Dispose()
        } catch { Write-ErrorLog "Prompt close: $($_.Exception.Message)" }
    })
 
    # Rounded corners on Windows 11 (ignored on Windows 10)
    $pref = 2; [void][Win]::DwmSetWindowAttribute($form.Handle, 33, [ref]$pref, 4)
 
    if (-not $Manual) { $grow.Start() }
    $expire.Start()
    $form.Show()
}
 
# ---- Tray icon & menu ------------------------------------------------------
function New-TrayIcon {
    $bmp = New-Object Drawing.Bitmap 32, 32
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([Drawing.Color]::Transparent)
    $g.FillEllipse((New-Object Drawing.SolidBrush $C.Accent), 1, 1, 30, 30)
    $pen = New-Object Drawing.Pen ([Drawing.Color]::White), 3
    $g.DrawLine($pen, 10, 10, 22, 10)
    $g.DrawLine($pen, 10, 16, 22, 16)
    $g.DrawLine($pen, 10, 22, 17, 22)
    $g.Dispose()
    [Drawing.Icon]::FromHandle($bmp.GetHicon())
}
 
function Update-Ui {
    if ($script:PausedUntil) {
        $t = if ($script:PausedUntil -eq [datetime]::MaxValue) { 'Daily Log - paused' }
             else { "Daily Log - paused until $($script:PausedUntil.ToString('HH:mm'))" }
    } else {
        $t = "Daily Log - next prompt $($script:NextDue.ToString('HH:mm'))"
    }
    $script:Tray.Text = $t
    $script:MiResume.Visible = [bool]$script:PausedUntil
    foreach ($mi in $script:IntervalItems) { $mi.Checked = ([int]$mi.Tag -eq [int]$script:S.IntervalMinutes) }
}
 
$menu = New-Object Windows.Forms.ContextMenuStrip
 
$script:MiLog = New-Object Windows.Forms.ToolStripMenuItem 'Log now'
$script:MiLog.Font = New-Object Drawing.Font($script:MiLog.Font, [Drawing.FontStyle]::Bold)
$script:MiLog.Add_Click({ Show-Prompt $true })
 
$miPause = New-Object Windows.Forms.ToolStripMenuItem 'Pause'
$pauseHandler = {
    $m = [int]$this.Tag
    $script:PausedUntil = if ($m -gt 0) { (Get-Date).AddMinutes($m) } else { [datetime]::MaxValue }
    Update-Ui
}
foreach ($opt in @(@('30 minutes', 30), @('1 hour', 60), @('2 hours', 120), @('Until resumed', 0))) {
    $mi = New-Object Windows.Forms.ToolStripMenuItem $opt[0]
    $mi.Tag = $opt[1]
    $mi.Add_Click($pauseHandler)
    [void]$miPause.DropDownItems.Add($mi)
}
$script:MiResume = New-Object Windows.Forms.ToolStripMenuItem 'Resume'
$script:MiResume.Add_Click({ $script:PausedUntil = $null; Update-Ui })
 
$miInterval = New-Object Windows.Forms.ToolStripMenuItem 'Interval'
$script:IntervalItems = @()
$intervalHandler = {
    $script:S.IntervalMinutes = [int]$this.Tag
    Save-Settings
    $script:NextDue = (Get-Date).AddMinutes($script:S.IntervalMinutes)
    Update-Ui
}
foreach ($m in 10, 15, 20, 30, 45, 60) {
    $mi = New-Object Windows.Forms.ToolStripMenuItem "$m minutes"
    $mi.Tag = $m
    $mi.Add_Click($intervalHandler)
    [void]$miInterval.DropDownItems.Add($mi)
    $script:IntervalItems += $mi
}
 
$miWeekends = New-Object Windows.Forms.ToolStripMenuItem 'Skip weekends'
$miWeekends.CheckOnClick = $true
$miWeekends.Checked = [bool]$script:S.SkipWeekends
$miWeekends.Add_Click({ $script:S.SkipWeekends = $this.Checked; Save-Settings })
 
$miChime = New-Object Windows.Forms.ToolStripMenuItem 'Chime on prompt'
$miChime.CheckOnClick = $true
$miChime.Checked = [bool]$script:S.Chime
$miChime.Add_Click({ $script:S.Chime = $this.Checked; Save-Settings })
 
$miOpenLog = New-Object Windows.Forms.ToolStripMenuItem "Open today's log"
$miOpenLog.Add_Click({
    try { Start-Process (Get-LogFile (Get-Date)) }
    catch { Start-Process explorer.exe $script:S.LogFolder }   # no app associated with .md
})
 
$miOpenFolder = New-Object Windows.Forms.ToolStripMenuItem 'Open log folder'
$miOpenFolder.Add_Click({ Start-Process explorer.exe $script:S.LogFolder })
 
$miChangeFolder = New-Object Windows.Forms.ToolStripMenuItem 'Change log folder...'
$miChangeFolder.Add_Click({ [void](Select-LogFolder) })
 
$miSettings = New-Object Windows.Forms.ToolStripMenuItem 'Edit settings... (restart to apply)'
$miSettings.Add_Click({ Start-Process notepad.exe $SettingsPath })
 
$miExit = New-Object Windows.Forms.ToolStripMenuItem 'Exit'
$miExit.Add_Click({ $script:Tray.Visible = $false; [Windows.Forms.Application]::Exit() })
 
[void]$menu.Items.AddRange(@(
    $script:MiLog,
    (New-Object Windows.Forms.ToolStripSeparator),
    $miPause, $script:MiResume, $miInterval, $miWeekends, $miChime,
    (New-Object Windows.Forms.ToolStripSeparator),
    $miOpenLog, $miOpenFolder, $miChangeFolder, $miSettings,
    (New-Object Windows.Forms.ToolStripSeparator),
    $miExit
))
 
$script:Tray = New-Object Windows.Forms.NotifyIcon
$script:Tray.Icon = New-TrayIcon
$script:Tray.ContextMenuStrip = $menu
$script:Tray.Visible = $true
$script:Tray.Add_DoubleClick({ Show-Prompt $true })
 
# ---- Hotkey ----------------------------------------------------------------
$script:Hk = New-Object HotkeyWindow
$script:HotkeyOk = $false
$hkSpec = ConvertTo-Hotkey $script:S.Hotkey
if ($hkSpec) {
    $script:HotkeyOk = $script:Hk.Register($hkSpec.Mods, $hkSpec.Vk)
    if ($script:HotkeyOk) {
        $script:MiLog.ShortcutKeyDisplayString = $script:S.Hotkey
        $script:Hk.add_Pressed({ try { Show-Prompt $true } catch { Write-ErrorLog "Hotkey: $($_.Exception.Message)" } })
    } else {
        Write-ErrorLog "Hotkey '$($script:S.Hotkey)' is already in use by another app."
    }
} elseif ($script:S.Hotkey) {
    Write-ErrorLog "Hotkey '$($script:S.Hotkey)' couldn't be understood. Example: Ctrl+Alt+L"
}
 
# ---- Timers ----------------------------------------------------------------
# Main schedule: checks the wall clock every 15s, so sleep/resume doesn't throw it off.
$tick = New-Object Windows.Forms.Timer
$tick.Interval = 15000
$tick.Add_Tick({
    try {
        $now = Get-Date
        $locked = Test-Locked
        if ($locked -and $script:P) { $script:P.Form.Tag = 'afk'; $script:P.Form.Close() }
        if ($script:PausedUntil -and $now -ge $script:PausedUntil) { $script:PausedUntil = $null; Update-Ui }
        if ($now -lt $script:NextDue) { return }
 
        $script:NextDue = $now.AddMinutes($script:S.IntervalMinutes)
        Update-Ui
 
        if ($script:PausedUntil) { return }
        if ($script:S.SkipWeekends -and $now.DayOfWeek -in 'Saturday', 'Sunday') { return }
        if ($locked) { return }
        if ($script:P) { return }                 # a prompt is already open
        if ([Win]::IdleSeconds() -ge ($script:S.IdleMinutes * 60)) { Write-AfkMarker $now; return }
        Show-Prompt $false
    } catch { Write-ErrorLog "Tick: $($_.Exception.Message)" }
})
function Test-Locked { [Win]::IsLocked() }
$tick.Start()
 
# Listens for a second launch of this script (e.g. from Raycast or a shortcut) and opens a prompt.
$signal = New-Object Windows.Forms.Timer
$signal.Interval = 300
$signal.Add_Tick({
   try { if ($script:ShowEvt.WaitOne(0)) { [void]$script:AckEvt.Set(); Show-Prompt $true } }
    catch { Write-ErrorLog "Signal: $($_.Exception.Message)" }
})
$signal.Start()
 
# ---- Run -------------------------------------------------------------------
Update-Ui
$startMsg = "Running. Next prompt at $($script:NextDue.ToString('HH:mm'))."
if ($script:HotkeyOk)        { $script:Tray.ShowBalloonTip(3000, 'Daily Log', "$startMsg Hotkey: $($script:S.Hotkey)", 'Info') }
elseif ($script:S.Hotkey)    { $script:Tray.ShowBalloonTip(5000, 'Daily Log', "$startMsg Hotkey $($script:S.Hotkey) unavailable - see DailyLog.errors.log", 'Warning') }
else                         { $script:Tray.ShowBalloonTip(3000, 'Daily Log', $startMsg, 'Info') }
 
[Windows.Forms.Application]::Run()
 
# ---- Cleanup ---------------------------------------------------------------
$tick.Stop(); $signal.Stop()
$script:Hk.Dispose()
$script:Tray.Dispose()
$script:ShowEvt.Dispose()
$script:Mutex.ReleaseMutex()
$script:AckEvt.Dispose()
 
