[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

docker compose stop mysql mysqld-exporter

if ($LASTEXITCODE -ne 0) {
    throw "failed to stop mysql and mysqld-exporter"
}

Write-Host "stopped mysql and mysqld-exporter to simulate a SetLog database outage"
