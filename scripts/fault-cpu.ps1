[CmdletBinding()]
param(
    [string] $BaseUrl,
    [System.Nullable[int]] $CpuWorkers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/lab-common.ps1"

$BaseUrl = Get-LabString -Value $BaseUrl -EnvName "BASE_URL" -Default "http://localhost:8080"
$CpuWorkers = Get-LabInt -Value $CpuWorkers -EnvName "CPU_WORKERS" -Default 4

Invoke-LabRequest `
    -Operation "enable CPU fault" `
    -Method "Post" `
    -Uri "$BaseUrl/internal/faults/cpu" `
    -Body @{ enabled = $true; workers = $CpuWorkers }
