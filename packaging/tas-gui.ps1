# remielle-tas launcher: edit tas.txt and inject remielle-tas.dll into the running game.
# Lives in the game folder next to tas-inject.exe, remielle-tas.dll and tas.txt; start it with tas-gui.cmd.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $dir 'tas.txt'
$injector = Join-Path $dir 'tas-inject.exe'
$dllLog = Join-Path $dir 'TAS\tas-dll.log'
$userLog = Join-Path $dir 'TAS\tas-log.txt'
$switches = @('sync', 'pin_team', 'pin_spawn', 'pin_assets', 'pin_random')

# --- tas.txt: key = value lines, '#' comments ------------------------------------------------
function Read-Config {
    $values = @{ mode = 'off'; file = 'TAS\run.inputtrace'; fps = '60'; speed = '1'; seed = '42' }
    foreach ($s in $switches) { $values[$s] = 'on' }
    if (Test-Path $configPath) {
        foreach ($line in Get-Content $configPath) {
            $text = ($line -split '#', 2)[0].Trim()
            if ($text -match '^\s*([A-Za-z_]+)\s*=\s*"?([^"]*)"?\s*$') { $values[$Matches[1].ToLower()] = $Matches[2].Trim() }
        }
    }
    return $values
}

function Write-Config($values) {
    $lines = @(
        '# TAS input record / playback (remielle-tas). Written by tas-gui; read at the start of every battle.',
        "mode = $($values.mode)",
        "file = $($values.file)",
        "fps = $($values.fps)",
        "speed = $($values.speed)",
        "seed = $($values.seed)"
    )
    foreach ($s in $switches) { $lines += "$s = $($values[$s])" }
    foreach ($k in $values.Keys) {
        if (@('mode', 'file', 'fps', 'speed', 'seed') + $switches -notcontains $k) { $lines += "$k = $($values[$k])" }
    }
    Set-Content -Path $configPath -Value $lines -Encoding ascii
}

# --- status ------------------------------------------------------------------------------
function Get-Status {
    $game = Get-Process ZenlessZoneZeroBeta -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $game) { return 'Game not running.' }
    $loaded = $false
    try { $loaded = [bool]($game.Modules | Where-Object { $_.ModuleName -eq 'remielle-tas.dll' }) } catch {}
    $state = if ($loaded) { 'Game running, TAS injected.' } else { 'Game running, TAS not injected.' }
    if ($loaded -and (Test-Path $dllLog)) {
        $last = Get-Content $dllLog -Tail 1
        if ($last) { $state += "`r`nDLL: $last" }
    }
    if (Test-Path $userLog) {
        $last = Get-Content $userLog -Tail 1
        if ($last) { $state += "`r`nLast: $last" }
    }
    return $state
}

# --- window ------------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'remielle-tas'
$form.ClientSize = New-Object System.Drawing.Size(460, 400)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$y = 12
function Add-Label($text, $top) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point(12, ($top + 3)); $l.AutoSize = $true
    $form.Controls.Add($l)
}

Add-Label 'Mode' $y
$mode = New-Object System.Windows.Forms.ComboBox
$mode.DropDownStyle = 'DropDownList'; [void]$mode.Items.AddRange(@('off', 'record', 'play'))
$mode.Location = New-Object System.Drawing.Point(90, $y); $mode.Width = 120
$form.Controls.Add($mode); $y += 30

Add-Label 'File' $y
$file = New-Object System.Windows.Forms.TextBox
$file.Location = New-Object System.Drawing.Point(90, $y); $file.Width = 270
$form.Controls.Add($file)
$browse = New-Object System.Windows.Forms.Button
$browse.Text = '...'; $browse.Location = New-Object System.Drawing.Point(368, ($y - 1)); $browse.Width = 40
$browse.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.InitialDirectory = Join-Path $dir 'TAS'
    $dialog.Filter = 'Recordings (*.inputtrace)|*.inputtrace|All files (*.*)|*.*'
    if ($dialog.ShowDialog() -eq 'OK') {
        $full = $dialog.FileName
        $file.Text = if ($full.StartsWith($dir + '\')) { $full.Substring($dir.Length + 1) } else { $full }
    }
})
$form.Controls.Add($browse); $y += 30

$numbers = @{}
foreach ($pair in @(@('fps', 'FPS'), @('speed', 'Speed (0 = max)'), @('seed', 'Seed'))) {
    Add-Label $pair[1] $y
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(120, $y); $box.Width = 90
    $form.Controls.Add($box); $numbers[$pair[0]] = $box; $y += 28
}

$checks = @{}
$x = 12
foreach ($s in $switches) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $s; $c.AutoSize = $true; $c.Location = New-Object System.Drawing.Point($x, $y)
    $form.Controls.Add($c); $checks[$s] = $c
    $x += 88
}
$y += 32

$save = New-Object System.Windows.Forms.Button
$save.Text = 'Save tas.txt'; $save.Location = New-Object System.Drawing.Point(12, $y); $save.Width = 110
$form.Controls.Add($save)
$inject = New-Object System.Windows.Forms.Button
$inject.Text = 'Inject'; $inject.Location = New-Object System.Drawing.Point(130, $y); $inject.Width = 110
$form.Controls.Add($inject)
$refresh = New-Object System.Windows.Forms.Button
$refresh.Text = 'Refresh'; $refresh.Location = New-Object System.Drawing.Point(248, $y); $refresh.Width = 80
$form.Controls.Add($refresh)
$y += 36

$status = New-Object System.Windows.Forms.TextBox
$status.Multiline = $true; $status.ReadOnly = $true; $status.ScrollBars = 'Vertical'
$status.Location = New-Object System.Drawing.Point(12, $y); $status.Size = New-Object System.Drawing.Size(436, (388 - $y))
$form.Controls.Add($status)

# --- behaviour -----------------------------------------------------------------------------
$config = Read-Config
function Show-Config {
    $mode.SelectedItem = if (@('off', 'record', 'play') -contains $config.mode) { $config.mode } else { 'off' }
    $file.Text = $config.file
    foreach ($k in $numbers.Keys) { $numbers[$k].Text = $config[$k] }
    foreach ($s in $switches) { $checks[$s].Checked = @('on', 'true', 'yes', '1') -contains "$($config[$s])".ToLower() }
}
Show-Config

$save.Add_Click({
    $config.mode = $mode.SelectedItem
    $config.file = $file.Text.Trim()
    foreach ($k in $numbers.Keys) { $config[$k] = $numbers[$k].Text.Trim() }
    foreach ($s in $switches) { $config[$s] = if ($checks[$s].Checked) { 'on' } else { 'off' } }
    Write-Config $config
    $status.Text = "Saved $configPath. It is read at the start of the next battle.`r`n" + (Get-Status)
})

$inject.Add_Click({
    if (-not (Test-Path $injector)) { $status.Text = "tas-inject.exe not found in $dir"; return }
    $status.Text = 'Injecting (waits up to 5 minutes for the game)...'
    $form.Refresh()
    $output = & $injector 2>&1 | Out-String
    $status.Text = $output.Trim() + "`r`n" + (Get-Status)
})

$refresh.Add_Click({ $status.Text = Get-Status })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({ if (-not $form.ContainsFocus -or $status.Text -notmatch 'Injecting') { $status.Text = Get-Status } })
$timer.Start()

$status.Text = Get-Status
[void]$form.ShowDialog()
