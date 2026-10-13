<#
  Quiet-Night.ps1  -  keep the screens dark between 21:00 and 07:00.

  Run it on each PC (BQIQ and HP) in PowerShell opened "as administrator".

    Step 1, look only (changes nothing):
      powershell -ExecutionPolicy Bypass -File .\Quiet-Night.ps1

    Step 2, apply the fixes:
      powershell -ExecutionPolicy Bypass -File .\Quiet-Night.ps1 -Apply

  What -Apply does:
    1. Turns off "wake the computer to run this task" on every task that has it.
    2. Moves your own tasks (not the built-in Microsoft ones) out of the quiet hours:
         starting 21:00-23:59  ->  20:15 the same evening
         starting 00:00-06:59  ->  07:15 the next morning
    3. Turns off Windows wake timers (mains and battery) and the
       "wake up for automatic maintenance" setting.
  Before changing any task it saves a copy of it, so every change can be undone:
      Register-ScheduledTask -Xml (Get-Content '<backup file>' -Raw) -TaskName '<name>' -TaskPath '<path>' -Force
  A report is written to the Desktop as QuietNight_<PC name>_<date>.txt
#>
param([switch]$Apply)

$QuietStart = 21   # quiet hours start (24h clock)
$QuietEnd   = 7    # quiet hours end
$Evening    = '20:15'
$Morning    = '07:15'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Warning 'Not running as administrator. Some tasks cannot be read or changed. Right-click PowerShell and choose "Run as administrator".' }

$stamp     = Get-Date -Format 'yyyy-MM-dd_HHmm'
$desktop   = [Environment]::GetFolderPath('Desktop')
$report    = Join-Path $desktop ("QuietNight_{0}_{1}.txt" -f $env:COMPUTERNAME, $stamp)
$backupDir = Join-Path $desktop ("QuietNight_Backup_{0}_{1}" -f $env:COMPUTERNAME, $stamp)
$lines     = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $lines.Add($s); Write-Host $s }

function In-Quiet([int]$h) { return ($h -ge $QuietStart -or $h -lt $QuietEnd) }

function Save-Backup($task) {
    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
    $file = Join-Path $backupDir (($task.TaskPath + $task.TaskName).Trim('\') -replace '[\\/:*?"<>|]', '_')
    Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath | Out-File -FilePath ($file + '.xml') -Encoding Unicode
}

# Moves the clock time inside a trigger start like 2026-10-01T02:00:00+02:00,
# keeping the date and time zone. Night times (00-06) go to the same morning, late evening (21-23) to the same evening.
function New-Start([string]$sb) {
    $m = [regex]::Match($sb, '^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})(:\d{2})?(.*)$')
    if (-not $m.Success) { return $null }
    $day  = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd', $null)
    $hour = [int]$m.Groups[2].Value
    if ($hour -ge $QuietStart) { $time = $Evening } else { $time = $Morning }
    return ('{0}T{1}:00{2}' -f $day.ToString('yyyy-MM-dd'), $time, $m.Groups[5].Value)
}

Say ("Quiet night check on {0}, {1}. Quiet hours {2}:00 to {3:00}:00. Mode: {4}" -f $env:COMPUTERNAME, (Get-Date -Format 'dddd d MMMM yyyy HH:mm'), $QuietStart, $QuietEnd, $(if ($Apply) { 'APPLY' } else { 'LOOK ONLY' }))
Say ''

$tasks = Get-ScheduledTask | Where-Object { $_.State -ne 'Disabled' }
$wakeFixed = 0; $moved = 0; $flagged = 0; $failed = 0

foreach ($t in $tasks) {
    $name    = $t.TaskPath + $t.TaskName
    $builtIn = $t.TaskPath -like '\Microsoft\*'
    $issues  = @()
    $changed = $false

    if ($t.Settings.WakeToRun) { $issues += 'can wake the PC' }

    $nightTriggers = @()
    foreach ($tr in $t.Triggers) {
        if (-not $tr.StartBoundary) { continue }
        $m = [regex]::Match($tr.StartBoundary, 'T(\d{2}):')
        if (-not $m.Success) { continue }
        $h = [int]$m.Groups[1].Value
        $repeats = $tr.Repetition -and $tr.Repetition.Interval
        if (In-Quiet $h) { $nightTriggers += $tr; $issues += ('starts at ' + ($tr.StartBoundary -replace '^.*T(\d{2}:\d{2}).*$', '$1')) }
        elseif ($repeats) { $issues += ('repeats every ' + $tr.Repetition.Interval + ', may run at night') }
    }
    if ($issues.Count -eq 0) { continue }

    $label = if ($builtIn) { '[Windows]' } else { '[yours]  ' }
    Say ("{0} {1}  ->  {2}" -f $label, $name, ($issues -join '; '))

    if (-not $Apply) { continue }
    try {
        Save-Backup $t
        if ($t.Settings.WakeToRun) { $t.Settings.WakeToRun = $false; $wakeFixed++; $changed = $true }
        if (-not $builtIn) {
            foreach ($tr in $nightTriggers) {
                $new = New-Start $tr.StartBoundary
                if ($new) { Say ("           moved {0}  ->  {1}" -f $tr.StartBoundary, $new); $tr.StartBoundary = $new; $moved++; $changed = $true }
            }
        } elseif ($nightTriggers.Count -gt 0) { $flagged++ }
        if ($changed) { Set-ScheduledTask -InputObject $t | Out-Null; Say '           done' }
    } catch {
        $failed++
        Say ('           could not change it: ' + $_.Exception.Message)
    }
}

Say ''
Say 'Power settings'
$wake = (powercfg /query SCHEME_CURRENT SUB_SLEEP RTCWAKE) -join "`n"
Say ('  Wake timers now: ' + $(if ($wake -match 'Current AC Power Setting Index:\s+0x0+\b') { 'off' } else { 'ON' }))
$mKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance'
$mWake = (Get-ItemProperty -Path $mKey -Name WakeUp -ErrorAction SilentlyContinue).WakeUp
Say ('  Automatic maintenance may wake the PC: ' + $(if ($mWake -eq 0) { 'no' } else { 'YES' }))
if ($Apply) {
    try {
        powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 0 | Out-Null
        powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 0 | Out-Null
        powercfg /setactive SCHEME_CURRENT | Out-Null
        if (-not (Test-Path $mKey)) { New-Item -Path $mKey -Force | Out-Null }
        Set-ItemProperty -Path $mKey -Name WakeUp -Value 0 -Type DWord
        Say '  Turned off wake timers and maintenance wake-up.'
    } catch { $failed++; Say ('  Could not change power settings: ' + $_.Exception.Message) }
}

Say ''
Say 'Devices allowed to wake the PC (mouse, keyboard, network card):'
(powercfg /devicequery wake_armed) | ForEach-Object { if ($_.Trim()) { Say ('  ' + $_) } }
Say ''
Say 'What woke the PC last time:'
(powercfg /lastwake) | ForEach-Object { if ($_.Trim()) { Say ('  ' + $_) } }

# Scheduled tasks kept inside the Claude desktop app (read only; change those in the app)
Say ''
Say 'Claude desktop app scheduled-task files (read only):'
$roots = @("$env:APPDATA\Claude", "$env:LOCALAPPDATA\Claude", "$env:LOCALAPPDATA\AnthropicClaude", "$env:USERPROFILE\.claude") | Where-Object { Test-Path $_ }
$found = $false
foreach ($r in $roots) {
    Get-ChildItem -Path $r -Recurse -File -Filter '*scheduled*task*' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(Cache|Code Cache|GPUCache|snapshots)\\' } | ForEach-Object {
            $found = $true
            Say ('  ' + $_.FullName)
            Select-String -Path $_.FullName -Pattern '"(cron|cronExpression|schedule|name|title)"\s*:' -ErrorAction SilentlyContinue |
                ForEach-Object { Say ('     ' + $_.Line.Trim()) }
        }
}
if (-not $found) { Say '  none found' }

Say ''
if ($Apply) {
    Say ("Summary: wake turned off on {0} task(s), {1} start time(s) moved, {2} Windows task(s) left at night but no longer able to wake the PC, {3} failure(s)." -f $wakeFixed, $moved, $flagged, $failed)
    Say ("Backups of changed tasks: {0}" -f $backupDir)
} else {
    Say 'Nothing was changed. Run again with -Apply to fix.'
}
$lines | Out-File -FilePath $report -Encoding UTF8
Write-Host ''
Write-Host ("Report saved to {0}" -f $report)
