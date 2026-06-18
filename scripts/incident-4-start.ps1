[CmdletBinding()]
param(
    [string] $BaseUrl,
    [System.Nullable[int]] $BaselineCount,
    [System.Nullable[int]] $IncidentCount,
    [System.Nullable[double]] $IncidentSleepSeconds,
    [System.Nullable[int]] $IncidentConcurrency,
    [System.Nullable[int]] $CpuWorkers,
    [System.Nullable[int]] $IncidentMaxCpuWorkers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/lab-common.ps1"
. "$PSScriptRoot/incident-common.ps1"

$cpuWorkersEnv = [Environment]::GetEnvironmentVariable("CPU_WORKERS")
$CpuWorkersExplicit = ($null -ne $CpuWorkers) -or (-not [string]::IsNullOrWhiteSpace($cpuWorkersEnv))

$BaselineCount = Get-LabInt -Value $BaselineCount -EnvName "BASELINE_COUNT" -Default 20
$IncidentCount = Get-LabInt -Value $IncidentCount -EnvName "INCIDENT_COUNT" -Default 12
$IncidentSleepSeconds = Get-LabDouble -Value $IncidentSleepSeconds -EnvName "INCIDENT_SLEEP_SECONDS" -Default 0.05
$IncidentConcurrency = Get-LabInt -Value $IncidentConcurrency -EnvName "INCIDENT_CONCURRENCY" -Default 3
$CpuWorkers = Get-LabInt -Value $CpuWorkers -EnvName "CPU_WORKERS" -Default 4
$IncidentMaxCpuWorkers = Get-LabInt -Value $IncidentMaxCpuWorkers -EnvName "INCIDENT_MAX_CPU_WORKERS" -Default 4
$ValidationWindow = Get-IncidentValidationWindow

$RenderP95Query = "histogram_quantile(0.95, sum(rate(http_server_requests_seconds_bucket{job=`"setlog`", uri=`"/api/render-jobs`"}[$ValidationWindow])) by (le))"
$RenderQueueMaxQuery = "max_over_time(setlog_vlog_render_queue_depth{job=`"setlog`"}[$ValidationWindow])"
$RenderFailureQuery = 'sum(setlog_vlog_render_jobs_total{job="setlog", result="failure"}) or vector(0)'
$CpuRatioQuery = 'sum(rate(container_cpu_usage_seconds_total{job="cadvisor", container_label_com_docker_compose_service="setlog", cpu="total"}[1m])) / clamp_min(sum(container_spec_cpu_quota{job="cadvisor", container_label_com_docker_compose_service="setlog"} / container_spec_cpu_period{job="cadvisor", container_label_com_docker_compose_service="setlog"}), 0.001)'

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

function Get-Incident4Metrics {
    Start-Sleep -Seconds (Get-IncidentScrapeWaitSeconds)

    $renderFailureAfter = Get-PrometheusNumber -Name "render_failure_total" -Query $RenderFailureQuery
    $renderFailureDelta = [Math]::Max(0, $renderFailureAfter - $script:RenderFailureBefore)
    $cpuRatio = 0.0
    $cpuDiagnostic = "unavailable"
    try {
        $cpuRatio = Get-PrometheusNumber -Name "cpu_ratio" -Query $CpuRatioQuery
        if ($cpuRatio -ge 0.6) {
            $cpuDiagnostic = "ok"
        } else {
            $cpuDiagnostic = "weak"
            Write-Warning "CPU metric weak on this runtime; cpuRatio=$cpuRatio, using render p95 and queue depth as primary signals"
        }
    } catch {
        Write-Warning "CPU metric unavailable on this runtime; using render p95 and queue depth as primary signals"
    }

    return @{
        RenderP95 = Get-PrometheusNumber -Name "render_p95" -Query $RenderP95Query
        RenderQueueMax = Get-PrometheusNumber -Name "render_queue_max" -Query $RenderQueueMaxQuery
        RenderFailureDelta = $renderFailureDelta
        CpuRatio = $cpuRatio
        CpuDiagnostic = $cpuDiagnostic
    }
}

function Test-Incident4MetricsPass {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Metrics
    )

    return ($Metrics.RenderP95 -ge 2) -and
        ($Metrics.RenderQueueMax -ge 1) -and
        ($Metrics.RenderFailureDelta -eq 0)
}

function Invoke-CpuPressureAttempt {
    param(
        [Parameter(Mandatory = $true)]
        [int] $AttemptWorkers
    )

    $faultAttemptArgs = @("-CpuWorkers", $AttemptWorkers)
    if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
        $faultAttemptArgs += @("-BaseUrl", $BaseUrl)
    }

    Write-Host "starting Incident 4: CPU pressure drill with CPU_WORKERS=$AttemptWorkers"
    & "$PSScriptRoot/fault-cpu.ps1" @faultAttemptArgs

    if ((Test-IncidentValidationEnabled) -or (Test-IncidentAutoTuneEnabled)) {
        $script:RenderFailureBefore = Get-PrometheusNumber -Name "render_failure_before" -Query $RenderFailureQuery
    } else {
        $script:RenderFailureBefore = 0.0
    }

    Write-Host "generating bounded render-heavy traffic while Incident 4 is active"
    Invoke-ConcurrentTraffic -Concurrency $IncidentConcurrency -TrafficArgs ([string[]] $script:IncidentArgs)

    if ((Test-IncidentValidationEnabled) -or (Test-IncidentAutoTuneEnabled)) {
        $script:Incident4Metrics = Get-Incident4Metrics
        Write-Host ("observed renderP95={0} renderQueueMax={1} renderFailureDelta={2} cpuRatio={3} with CPU_WORKERS={4}" -f $script:Incident4Metrics.RenderP95, $script:Incident4Metrics.RenderQueueMax, $script:Incident4Metrics.RenderFailureDelta, $script:Incident4Metrics.CpuRatio, $AttemptWorkers)
    }
}

function Invoke-AdaptiveCpuPressureDrill {
    if ((Test-IncidentAutoTuneEnabled) -and (-not $CpuWorkersExplicit)) {
        for ($attemptWorkers = 1; $attemptWorkers -le $IncidentMaxCpuWorkers; $attemptWorkers++) {
            Invoke-CpuPressureAttempt -AttemptWorkers $attemptWorkers

            if ($script:Incident4Metrics.RenderFailureDelta -ne 0) {
                throw "Incident 4 generated render failures at CPU_WORKERS=$attemptWorkers; expected CPU pressure without failures"
            }

            if (Test-Incident4MetricsPass -Metrics $script:Incident4Metrics) {
                return $attemptWorkers
            }
        }

        throw "Incident 4 render symptoms did not reach renderP95>=2s and renderQueueMax>=1 up to INCIDENT_MAX_CPU_WORKERS=$IncidentMaxCpuWorkers; try increasing INCIDENT_CONCURRENCY or INCIDENT_COUNT"
    }

    if (Test-IncidentAutoTuneEnabled) {
        Write-Host "CPU_WORKERS is explicitly set; using CPU_WORKERS=$CpuWorkers without auto-tuning"
    } else {
        Write-Host "INCIDENT_AUTO_TUNE is disabled; using CPU_WORKERS=$CpuWorkers"
    }

    Invoke-CpuPressureAttempt -AttemptWorkers $CpuWorkers
    return $CpuWorkers
}

$baseArgs = @("-Count", $BaselineCount)
$script:IncidentArgs = @("-Count", $IncidentCount, "-SleepSeconds", $IncidentSleepSeconds, "-RenderEvery", 1)

if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
    $baseArgs += @("-BaseUrl", $BaseUrl)
    $script:IncidentArgs += @("-BaseUrl", $BaseUrl)
}

Write-Host "preparing Incident 4 with baseline SetLog traffic"
& "$PSScriptRoot/baseline-traffic.ps1" @baseArgs

$chosenCpuWorkers = Invoke-AdaptiveCpuPressureDrill

Write-Host "Incident 4 is active. Open Grafana and complete the incident table."
if (Test-IncidentValidationEnabled) {
    Assert-IncidentGe -Name "renderP95" -Value $script:Incident4Metrics.RenderP95 -Threshold 2
    Assert-IncidentGe -Name "renderQueueMax" -Value $script:Incident4Metrics.RenderQueueMax -Threshold 1
    Assert-IncidentEq -Name "renderFailureDelta" -Value $script:Incident4Metrics.RenderFailureDelta -Expected 0
    Write-IncidentSummary @{
        incident = 4
        passed = $true
        renderP95 = $script:Incident4Metrics.RenderP95
        renderQueueMax = $script:Incident4Metrics.RenderQueueMax
        renderFailureDelta = $script:Incident4Metrics.RenderFailureDelta
        cpuRatio = $script:Incident4Metrics.CpuRatio
        cpuDiagnostic = $script:Incident4Metrics.CpuDiagnostic
        chosenCpuWorkers = $chosenCpuWorkers
    }
} else {
    Write-IncidentSummary @{
        incident = 4
        passed = $true
        validationSkipped = $true
        chosenCpuWorkers = $chosenCpuWorkers
    }
}
