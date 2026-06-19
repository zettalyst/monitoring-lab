[CmdletBinding()]
param(
    [string] $BaseUrl,
    [string] $PrometheusUrl,
    [int] $WaitAttempts = 90,
    [double] $WaitSleepSeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$BaseUrl = if ([string]::IsNullOrWhiteSpace($BaseUrl)) { "http://localhost:8080" } else { $BaseUrl }
$PrometheusUrl = if ([string]::IsNullOrWhiteSpace($PrometheusUrl)) { "http://localhost:9090" } else { $PrometheusUrl }

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string] $File,
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    & $File @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$File $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Wait-Http {
    param([string] $Name, [string] $Uri)

    for ($attempt = 1; $attempt -le $WaitAttempts; $attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Method Get -Uri $Uri -TimeoutSec 5 | Out-Null
            return
        } catch {
            Start-Sleep -Seconds $WaitSleepSeconds
        }
    }

    throw "timed out waiting for $Name at $Uri"
}

function Wait-Stack {
    Wait-Http -Name "setlog" -Uri "$BaseUrl/actuator/health"
    Wait-Http -Name "prometheus" -Uri "$PrometheusUrl/-/ready"
}

function Reset-Lab {
    & "$PSScriptRoot/fault-clear.ps1"
    Wait-Stack
}

function Get-FaultStatus {
    return Invoke-RestMethod -Method Get -Uri "$BaseUrl/internal/faults" -TimeoutSec 10
}

function Assert-FaultField {
    param([string] $Field, [bool] $Expected)

    $status = Get-FaultStatus
    if ([bool] $status.$Field -ne $Expected) {
        throw "unexpected fault status $Field=$($status.$Field), expected $Expected. Full status: $($status | ConvertTo-Json -Compress)"
    }
}

function Wait-FaultField {
    param([string] $Field, [bool] $Expected)

    for ($attempt = 1; $attempt -le $WaitAttempts; $attempt++) {
        try {
            Assert-FaultField -Field $Field -Expected $Expected
            return
        } catch {
            if ($attempt -eq $WaitAttempts) {
                throw
            }
            Start-Sleep -Seconds $WaitSleepSeconds
        }
    }
}

function Get-MysqlHolderIds {
    $query = "SELECT ID FROM information_schema.PROCESSLIST WHERE ID <> CONNECTION_ID() AND INFO LIKE '%SRE301_I1_DB_POOL_HOLDER%';"
    $output = & docker compose exec -T mysql mysql -N -uroot -proot -e $query
    if ($LASTEXITCODE -ne 0) {
        throw "failed to read MySQL processlist"
    }
    return @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Kill-MysqlHolders {
    $ids = Get-MysqlHolderIds
    if ($ids.Count -eq 0) {
        & docker compose exec -T mysql mysql -uroot -proot -e "SHOW FULL PROCESSLIST;"
        throw "no SRE301_I1_DB_POOL_HOLDER sessions found"
    }

    foreach ($id in $ids) {
        Invoke-CheckedCommand -File "docker" -Arguments @("compose", "exec", "-T", "mysql", "mysql", "-uroot", "-proot", "-e", "KILL $id;")
    }
}

function Test-BaselineRestartPreservesFaults {
    Write-Host "checking baseline-traffic restart preserves app faults by default"
    Reset-Lab
    & "$PSScriptRoot/fault-latency.ps1" | Out-Null
    Wait-FaultField -Field "dbPoolActive" -Expected $true

    Invoke-CheckedCommand -File "docker" -Arguments @("compose", "restart", "baseline-traffic")
    Start-Sleep -Seconds 5
    Assert-FaultField -Field "dbPoolActive" -Expected $true

    Write-Host "checking baseline-traffic opt-in clear still clears app faults"
    $oldClear = [Environment]::GetEnvironmentVariable("BASELINE_CLEAR_FAULTS_ON_START")
    try {
        $env:BASELINE_CLEAR_FAULTS_ON_START = "1"
        Invoke-CheckedCommand -File "docker" -Arguments @("compose", "up", "-d", "--force-recreate", "baseline-traffic")
        Wait-FaultField -Field "dbPoolActive" -Expected $false
    } finally {
        if ($null -eq $oldClear) {
            Remove-Item Env:BASELINE_CLEAR_FAULTS_ON_START -ErrorAction SilentlyContinue
        } else {
            $env:BASELINE_CLEAR_FAULTS_ON_START = $oldClear
        }
    }

    Invoke-CheckedCommand -File "docker" -Arguments @("compose", "up", "-d", "--force-recreate", "baseline-traffic")
    Reset-Lab
}

function Test-Incident1 {
    Write-Host "checking Incident 1 SQL KILL mitigation"
    Reset-Lab
    & "$PSScriptRoot/incident-1-start.ps1"
    Wait-FaultField -Field "dbPoolActive" -Expected $true
    Kill-MysqlHolders
    Wait-FaultField -Field "dbPoolActive" -Expected $false
    Reset-Lab
}

function Test-Incident2 {
    Write-Host "checking Incident 2 dependency restart mitigation"
    Reset-Lab
    & "$PSScriptRoot/incident-2-start.ps1"
    Invoke-CheckedCommand -File "docker" -Arguments @("compose", "up", "-d", "mysql", "mysqld-exporter")
    Wait-Http -Name "setlog" -Uri "$BaseUrl/actuator/health"
    Reset-Lab
}

function Test-Incident3 {
    Write-Host "checking Incident 3 debug log removal mitigation"
    Reset-Lab
    & "$PSScriptRoot/incident-3-start.ps1"
    Invoke-CheckedCommand -File "docker" -Arguments @("compose", "exec", "-T", "setlog", "sh", "-c", "test -e /tmp/sre301-render-debug.log")
    Invoke-CheckedCommand -File "docker" -Arguments @("compose", "exec", "-T", "setlog", "rm", "-f", "/tmp/sre301-render-debug.log")
    Invoke-CheckedCommand -File "docker" -Arguments @("compose", "exec", "-T", "setlog", "sh", "-c", "test ! -e /tmp/sre301-render-debug.log")
    Reset-Lab
}

function Test-Incident4 {
    Write-Host "checking Incident 4 setlog restart mitigation"
    Reset-Lab
    & "$PSScriptRoot/incident-4-start.ps1"
    Assert-FaultField -Field "cpuActive" -Expected $true
    Invoke-CheckedCommand -File "docker" -Arguments @("compose", "restart", "setlog")
    Invoke-CheckedCommand -File "docker" -Arguments @("compose", "restart", "setlog-netem")
    Wait-Http -Name "setlog" -Uri "$BaseUrl/actuator/health"
    Wait-FaultField -Field "cpuActive" -Expected $false
    Reset-Lab
}

Push-Location $repoRoot
try {
    Write-Host "starting SRE301 stack for live mitigation verification"
    Invoke-CheckedCommand -File "docker" -Arguments @("compose", "up", "--build", "-d")
    Wait-Stack

    Test-BaselineRestartPreservesFaults
    Test-Incident1
    Test-Incident2
    Test-Incident3
    Test-Incident4
    Write-Host "live mitigation verification complete"
} finally {
    Pop-Location
}
