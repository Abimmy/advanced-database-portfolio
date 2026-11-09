<#
.SYNOPSIS
  Start, stop or crash the three local MongoDB replica-set members (mikepay-rs) used in Portfolio 5.

.DESCRIPTION
  start : create the data folders if needed and start the node(s) as hidden background processes
  stop  : clean shutdown (db.shutdownServer() through mongosh), like a planned maintenance stop
  kill  : Stop-Process -Force, an abrupt crash with no shutdown work (simulates a process or host failure)
  status: show which nodes are running

  Node 1 listens on 27018, node 2 on 27019, node 3 on 27020 (the original MongoDB service on 27017 is not touched).

.EXAMPLE
  powershell -NoProfile -File node-control.ps1 -Action start
  powershell -NoProfile -File node-control.ps1 -Action kill -Node 1
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('start', 'stop', 'kill', 'status')][string]$Action,
    [string]$Node = 'all'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$mongod = 'C:\Program Files\MongoDB\Server\9.0\bin\mongod.exe'
$mongosh = Join-Path $env:LOCALAPPDATA 'Programs\mongosh\mongosh.exe'
$nodes = if ($Node -eq 'all') { 1, 2, 3 } else { [int]$Node }

function Get-NodeProcess([int]$n) {
    Get-CimInstance Win32_Process -Filter "Name = 'mongod.exe'" |
        Where-Object { $_.CommandLine -like "*mongod-node$n.conf*" }
}

foreach ($n in $nodes) {
    $port = 27017 + $n
    $proc = Get-NodeProcess $n
    switch ($Action) {
        'start' {
            if ($proc) { Write-Output "node$n (port $port): already running, PID $($proc.ProcessId)"; continue }
            New-Item -ItemType Directory -Force -Path (Join-Path $root "mongo-data\node$n\db") | Out-Null
            $p = Start-Process -FilePath $mongod -ArgumentList "--config `"$(Join-Path $here "mongod-node$n.conf")`"" -WindowStyle Hidden -PassThru
            Write-Output "node$n (port $port): started, PID $($p.Id)"
        }
        'stop' {
            if (-not $proc) { Write-Output "node$n (port $port): not running"; continue }
            & $mongosh --quiet --port $port --eval "try { db.getSiblingDB('admin').shutdownServer({force: true}) } catch (e) { print('shutdown requested') }" | Out-Null
            Wait-Process -Id $proc.ProcessId -Timeout 60 -ErrorAction SilentlyContinue
            Write-Output "node$n (port $port): stopped cleanly"
        }
        'kill' {
            if (-not $proc) { Write-Output "node$n (port $port): not running"; continue }
            Stop-Process -Id $proc.ProcessId -Force
            Write-Output "node$n (port $port): KILLED (PID $($proc.ProcessId))"
        }
        'status' {
            if ($proc) { Write-Output "node$n (port $port): running, PID $($proc.ProcessId)" } else { Write-Output "node$n (port $port): not running" }
        }
    }
}
