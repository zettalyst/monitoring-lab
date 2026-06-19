[CmdletBinding()]
param(
    [string] $BaseUrl,
    [System.Nullable[int]] $LatencyMs,
    [System.Nullable[int]] $DbPoolHolders,
    [System.Nullable[int]] $DbPoolHoldMillis
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/lab-common.ps1"

$BaseUrl = Get-LabString -Value $BaseUrl -EnvName "BASE_URL" -Default "http://localhost:8080"
$LatencyMs = Get-LabInt -Value $LatencyMs -EnvName "LATENCY_MS" -Default 0
$DbPoolHolders = Get-LabInt -Value $DbPoolHolders -EnvName "DB_POOL_HOLDERS" -Default 4
$DbPoolHoldMillis = Get-LabInt -Value $DbPoolHoldMillis -EnvName "DB_POOL_HOLD_MILLIS" -Default 300000

if ($LatencyMs -lt 0) {
    throw "LatencyMs must be non-negative, got: $LatencyMs"
}

if ($DbPoolHolders -lt 1) {
    throw "DbPoolHolders must be positive, got: $DbPoolHolders"
}

if ($DbPoolHoldMillis -lt 1000) {
    throw "DbPoolHoldMillis must be at least 1000, got: $DbPoolHoldMillis"
}

Invoke-LabRequest `
    -Operation "enable DB pool contention fault" `
    -Method "Post" `
    -Uri "$BaseUrl/internal/faults/db-pool" `
    -Body @{ enabled = $true; holders = $DbPoolHolders; holdMillis = $DbPoolHoldMillis } | Out-Null

Invoke-LabRequest `
    -Operation "configure API latency fault" `
    -Method "Post" `
    -Uri "$BaseUrl/internal/faults/latency" `
    -Body @{ latencyMs = $LatencyMs }
