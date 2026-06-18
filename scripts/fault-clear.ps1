[CmdletBinding()]
param(
    [string] $BaseUrl,
    [switch] $SkipCompose
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/lab-common.ps1"

$BaseUrl = Get-LabString -Value $BaseUrl -EnvName "BASE_URL" -Default "http://localhost:8080"
$skipComposeEnv = Get-LabString -Value "" -EnvName "FAULT_CLEAR_SKIP_COMPOSE" -Default "0"

Invoke-LabRequest -Operation "clear faults" -Method "Delete" -Uri "$BaseUrl/internal/faults"

if ($SkipCompose.IsPresent -or $skipComposeEnv -in @("1", "true", "TRUE", "True")) {
    Write-Host ("cleared app faults at {0} and skipped compose service recovery because FAULT_CLEAR_SKIP_COMPOSE={1}" -f $BaseUrl, $skipComposeEnv)
    return
}

docker compose up -d mysql mysqld-exporter setlog

if ($LASTEXITCODE -ne 0) {
    throw "failed to ensure mysql, mysqld-exporter, and setlog are running"
}

Write-Host "cleared app faults and ensured mysql, mysqld-exporter, and setlog are running"
