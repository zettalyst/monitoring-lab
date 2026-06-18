[CmdletBinding()]
param(
    [switch] $SkipGradleTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$dashboardPath = Join-Path $repoRoot "grafana/dashboards/sre301/golden-signals.json"
$dashboardRulesPath = Join-Path $repoRoot (".sre301-dashboard-rules.{0}.yml" -f ([System.Guid]::NewGuid().ToString("N")))
$demoServicePath = Join-Path $repoRoot "demo-service"

Write-Output "checking docker compose config"
Push-Location $repoRoot
try {
    & docker compose config --quiet
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose config failed with exit code $LASTEXITCODE"
    }

    Write-Output "checking Grafana dashboard JSON"
    Get-Content -Raw $dashboardPath | ConvertFrom-Json | Out-Null

    Write-Output "checking Bear generated sources"
    & python3 scripts/sync-bear-sources.py --check
    if ($LASTEXITCODE -ne 0) {
        throw "Bear source sync check failed with exit code $LASTEXITCODE"
    }

    Write-Output "checking Grafana dashboards, panels, and query extraction"
    & python3 scripts/verify-sre301-assets.py --dashboard-rules-out $dashboardRulesPath
    if ($LASTEXITCODE -ne 0) {
        throw "SRE301 asset verification failed with exit code $LASTEXITCODE"
    }

    Write-Output "checking Prometheus config and alert rules"
    & docker run --rm -v "${repoRoot}/prometheus:/etc/prometheus:ro" --entrypoint promtool prom/prometheus check config /etc/prometheus/prometheus.yml
    if ($LASTEXITCODE -ne 0) {
        throw "Prometheus config verification failed with exit code $LASTEXITCODE"
    }

    Write-Output "checking Grafana dashboard PromQL syntax"
    $dashboardRulesFileName = Split-Path -Leaf $dashboardRulesPath
    & docker run --rm -v "${repoRoot}:/workspace:ro" --entrypoint promtool prom/prometheus check rules "/workspace/$dashboardRulesFileName"
    if ($LASTEXITCODE -ne 0) {
        throw "Grafana dashboard PromQL verification failed with exit code $LASTEXITCODE"
    }

    if (-not $SkipGradleTest) {
        Write-Output "running Dockerized Gradle tests"
        & docker run --rm -v "${demoServicePath}:/workspace" -w /workspace gradle:8.14.3-jdk21 gradle --no-daemon test
        if ($LASTEXITCODE -ne 0) {
            throw "Dockerized Gradle tests failed with exit code $LASTEXITCODE"
        }
    }
} finally {
    Remove-Item -LiteralPath $dashboardRulesPath -Force -ErrorAction SilentlyContinue
    Pop-Location
}

Write-Output "verification complete"
