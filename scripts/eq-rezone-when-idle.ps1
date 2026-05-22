# Waits until the EQ player is out of combat, then camps + re-enters to give
# the daemon a fresh (decryptable) session. EQ blocks /camp during combat, so
# we watch the log and only camp once combat has been quiet for a while.
param([int]$IdleSec = 25, [int]$MaxWaitSec = 900)

$log = "E:\EQ\Logs\eqlog_Zerkdan_mischief.txt"
$ctrl = Join-Path $PSScriptRoot 'eq-control.ps1'
$combat = 'tries to (hit|bash|slash|pierce|kick|crush|bite|gore|sting|claw|punch|maul)|hits YOU|points of damage|You have slain|has been slain|You begin to cast|You can(no)?t see your target|YOU, but'

$deadline = (Get-Date).AddSeconds($MaxWaitSec)
while ((Get-Date) -lt $deadline) {
  $lines = Get-Content $log -Tail 50 -ErrorAction SilentlyContinue
  $cl = $lines | Where-Object { $_ -match $combat } | Select-Object -Last 1
  $age = 9999
  if ($cl -and ($cl -match '^\[(.+?)\]')) {
    try { $age = ((Get-Date) - [datetime]::Parse($matches[1].Replace(' EDT',''))).TotalSeconds } catch {}
  }
  if ($age -ge $IdleSec) {
    & $ctrl -Mode rezone -CampWaitSec 38 | Out-Null
    Start-Sleep -Seconds 4
    $tail = Get-Content $log -Tail 8
    if ($tail -match 'LOADING|Welcome to EverQuest|You have entered') { Write-Output "REZONED_OK" }
    else { Write-Output "REZONE_SENT_UNVERIFIED" }
    return
  }
  Start-Sleep -Seconds 8
}
Write-Output "TIMEOUT_STILL_IN_COMBAT"
