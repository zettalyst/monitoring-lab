[CmdletBinding()]
param(
    [string] $BaseUrl,
    [System.Nullable[int]] $BaselineCount,
    [System.Nullable[int]] $IncidentCount,
    [System.Nullable[double]] $IncidentSleepSeconds,
    [System.Nullable[int]] $IncidentConcurrency,
    [System.Nullable[int]] $DbPoolProbeConcurrency,
    [System.Nullable[int]] $IncidentMaxConcurrency,
    [System.Nullable[int]] $DbPoolProbeWaves,
    [System.Nullable[double]] $DbPoolProbeSleepSeconds
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/lab-common.ps1"
. "$PSScriptRoot/incident-common.ps1"

$BaselineCount = Get-LabInt -Value $BaselineCount -EnvName "BASELINE_COUNT" -Default 20
$IncidentCount = Get-LabInt -Value $IncidentCount -EnvName "INCIDENT_COUNT" -Default 45
$IncidentSleepSeconds = Get-LabDouble -Value $IncidentSleepSeconds -EnvName "INCIDENT_SLEEP_SECONDS" -Default 0.05
$IncidentConcurrency = Get-LabInt -Value $IncidentConcurrency -EnvName "INCIDENT_CONCURRENCY" -Default 2
$DbPoolProbeConcurrency = Get-LabInt -Value $DbPoolProbeConcurrency -EnvName "DB_POOL_PROBE_CONCURRENCY" -Default 2
$IncidentMaxConcurrency = Get-LabInt -Value $IncidentMaxConcurrency -EnvName "INCIDENT_MAX_CONCURRENCY" -Default 8
$DbPoolProbeWaves = Get-LabInt -Value $DbPoolProbeWaves -EnvName "DB_POOL_PROBE_WAVES" -Default 12
$DbPoolProbeSleepSeconds = Get-LabDouble -Value $DbPoolProbeSleepSeconds -EnvName "DB_POOL_PROBE_SLEEP_SECONDS" -Default 0.2
$ProbeBaseUrl = Get-LabString -Value $BaseUrl -EnvName "BASE_URL" -Default "http://localhost:8080"
$ValidationWindow = Get-IncidentValidationWindow

$ApiTotalQuery = 'sum(http_server_requests_seconds_count{job="setlog", uri=~"/api/.*"}) or vector(0)'
$Api5xxQuery = 'sum(http_server_requests_seconds_count{job="setlog", uri=~"/api/.*", status=~"5.."}) or vector(0)'
$ApiP95Query = "max(histogram_quantile(0.95, sum(rate(http_server_requests_seconds_bucket{job=`"setlog`", uri=~`"/api/.*`", status!~`"5..`"}[$ValidationWindow])) by (le, method, uri)))"
$DbPendingMaxQuery = "max_over_time(hikaricp_connections_pending{job=`"setlog`"}[$ValidationWindow])"

function Invoke-ConcurrentTraffic {
    param(
        [Parameter(Mandatory = $true)]
        [int] $Concurrency,
        [Parameter(Mandatory = $true)]
        [string[]] $TrafficArgs
    )

    $jobs = @()
    $trafficScript = Join-Path $PSScriptRoot "baseline-traffic.ps1"
    for ($worker = 1; $worker -le $Concurrency; $worker++) {
        $jobs += Start-Job -ScriptBlock {
            param(
                [string] $ScriptPath,
                [string[]] $ScriptArgs
            )
            & $ScriptPath @ScriptArgs
        } -ArgumentList $trafficScript, (, $TrafficArgs)
    }

    $failed = $false
    try {
        foreach ($job in $jobs) {
            Wait-Job -Job $job | Out-Null
            Receive-Job -Job $job
            if ($job.State -ne "Completed") {
                $failed = $true
            }
        }
    } finally {
        $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    }

    if ($failed) {
        throw "one or more traffic workers failed"
    }
}

function Invoke-DbPoolProbeTraffic {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Url,
        [Parameter(Mandatory = $true)]
        [int] $Concurrency,
        [Parameter(Mandatory = $true)]
        [int] $Waves,
        [Parameter(Mandatory = $true)]
        [double] $SleepSeconds
    )

    for ($wave = 1; $wave -le $Waves; $wave++) {
        $jobs = @()
        for ($request = 1; $request -le $Concurrency; $request++) {
            $jobs += Start-Job -ScriptBlock {
                param([string] $Uri)
                Invoke-RestMethod -Method Get -Uri $Uri -TimeoutSec 30 | Out-Null
            } -ArgumentList "$Url/api/feed"
        }

        $failed = $false
        try {
            foreach ($job in $jobs) {
                Wait-Job -Job $job | Out-Null
                try {
                    Receive-Job -Job $job -ErrorAction Stop
                } catch {
                    Write-Error $_ -ErrorAction Continue
                    $failed = $true
                }
                if ($job.State -ne "Completed") {
                    $failed = $true
                }
            }
        } finally {
            $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
        }

        if ($failed) {
            throw "one or more DB pool probe requests failed"
        }

        Start-Sleep -Seconds $SleepSeconds
    }
}

function Get-Incident1Metrics {
    $apiTotalAfter = Get-PrometheusNumber -Name "api_total" -Query $ApiTotalQuery
    $api5xxAfter = Get-PrometheusNumber -Name "api_5xx" -Query $Api5xxQuery
    $apiTotalDelta = [Math]::Max(0, $apiTotalAfter - $script:ApiTotalBefore)
    $api5xxDelta = [Math]::Max(0, $api5xxAfter - $script:Api5xxBefore)
    $errorRatio = 0.0
    if ($apiTotalDelta -gt 0) {
        $errorRatio = $api5xxDelta / $apiTotalDelta
    }

    return @{
        ApiP95 = Get-PrometheusNumber -Name "api_p95" -Query $ApiP95Query
        DbPendingMax = Get-PrometheusNumber -Name "db_pending_max" -Query $DbPendingMaxQuery
        ErrorRatio = $errorRatio
    }
}

function Invoke-AdaptiveDbPoolProbe {
    if (-not (Test-IncidentAutoTuneEnabled)) {
        Write-Host "INCIDENT_AUTO_TUNE is disabled; using DB pool probe concurrency $DbPoolProbeConcurrency"
        try {
            Invoke-DbPoolProbeTraffic -Url $ProbeBaseUrl -Concurrency $DbPoolProbeConcurrency -Waves $DbPoolProbeWaves -SleepSeconds $DbPoolProbeSleepSeconds
        } catch {
            throw "DB pool probe too aggressive at concurrency ${DbPoolProbeConcurrency}: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds (Get-IncidentScrapeWaitSeconds)
        return $DbPoolProbeConcurrency
    }

    for ($concurrency = $DbPoolProbeConcurrency; $concurrency -le $IncidentMaxConcurrency; $concurrency++) {
        Write-Host "probing DB pool contention with concurrency $concurrency"
        try {
            Invoke-DbPoolProbeTraffic -Url $ProbeBaseUrl -Concurrency $concurrency -Waves $DbPoolProbeWaves -SleepSeconds $DbPoolProbeSleepSeconds
        } catch {
            throw "DB pool probe too aggressive at concurrency ${concurrency}: $($_.Exception.Message)"
        }

        Start-Sleep -Seconds (Get-IncidentScrapeWaitSeconds)
        $metrics = Get-Incident1Metrics
        Write-Host ("observed dbPendingMax={0} apiP95={1} errorRatio={2} at DB probe concurrency {3}" -f $metrics.DbPendingMax, $metrics.ApiP95, $metrics.ErrorRatio, $concurrency)

        if ($metrics.ErrorRatio -gt 0.01) {
            throw "DB pool probe too aggressive at concurrency ${concurrency}: errorRatio=$($metrics.ErrorRatio) exceeded 0.01"
        }

        if ($metrics.DbPendingMax -ge 1) {
            return $concurrency
        }
    }

    throw "DB pool pending did not reach 1 up to INCIDENT_MAX_CONCURRENCY=$IncidentMaxConcurrency; try increasing DB_POOL_HOLDERS or INCIDENT_MAX_CONCURRENCY"
}

$baseArgs = @("-Count", $BaselineCount)
$faultArgs = @()
$incidentArgs = @("-Count", $IncidentCount, "-SleepSeconds", $IncidentSleepSeconds)

if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
    $baseArgs += @("-BaseUrl", $BaseUrl)
    $faultArgs += @("-BaseUrl", $BaseUrl)
    $incidentArgs += @("-BaseUrl", $BaseUrl)
}

Write-Host "preparing Incident 1 with baseline SetLog traffic"
& "$PSScriptRoot/baseline-traffic.ps1" @baseArgs

if ((Test-IncidentValidationEnabled) -or (Test-IncidentAutoTuneEnabled)) {
    $script:ApiTotalBefore = Get-PrometheusNumber -Name "api_total_before" -Query $ApiTotalQuery
    $script:Api5xxBefore = Get-PrometheusNumber -Name "api_5xx_before" -Query $Api5xxQuery
} else {
    $script:ApiTotalBefore = 0.0
    $script:Api5xxBefore = 0.0
}

Write-Host "starting Incident 1: DB pool latency drill"
& "$PSScriptRoot/fault-latency.ps1" @faultArgs

Write-Host "generating bounded concurrent traffic while Incident 1 is active"
Invoke-ConcurrentTraffic -Concurrency $IncidentConcurrency -TrafficArgs ([string[]] $incidentArgs)

Write-Host "generating DB pool diagnostic probe traffic while Incident 1 is active"
$chosenConcurrency = Invoke-AdaptiveDbPoolProbe

Write-Host "Incident 1 is active. Open Grafana and complete the incident table."
if (Test-IncidentValidationEnabled) {
    $metrics = Get-Incident1Metrics
    Assert-IncidentGe -Name "apiP95" -Value $metrics.ApiP95 -Threshold 0.8
    Assert-IncidentGe -Name "dbPendingMax" -Value $metrics.DbPendingMax -Threshold 1
    Assert-IncidentLe -Name "errorRatio" -Value $metrics.ErrorRatio -Threshold 0.01
    Write-IncidentSummary @{
        incident = 1
        passed = $true
        apiP95 = $metrics.ApiP95
        dbPendingMax = $metrics.DbPendingMax
        errorRatio = $metrics.ErrorRatio
        chosenConcurrency = $chosenConcurrency
    }
} else {
    Write-IncidentSummary @{
        incident = 1
        passed = $true
        validationSkipped = $true
        chosenConcurrency = $chosenConcurrency
    }
}
