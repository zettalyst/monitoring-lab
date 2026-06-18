[CmdletBinding()]
param(
    [string] $BaseUrl,
    [System.Nullable[int]] $BaselineCount,
    [System.Nullable[int]] $IncidentCount,
    [System.Nullable[double]] $IncidentSleepSeconds
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/lab-common.ps1"
. "$PSScriptRoot/incident-common.ps1"

$BaselineCount = Get-LabInt -Value $BaselineCount -EnvName "BASELINE_COUNT" -Default 20
$IncidentCount = Get-LabInt -Value $IncidentCount -EnvName "INCIDENT_COUNT" -Default 90
$IncidentSleepSeconds = Get-LabDouble -Value $IncidentSleepSeconds -EnvName "INCIDENT_SLEEP_SECONDS" -Default 0.7

$RenderTotalQuery = 'sum(setlog_vlog_render_jobs_total{job="setlog"}) or vector(0)'
$RenderDiskFailureQuery = 'sum(setlog_vlog_render_jobs_total{job="setlog", result="failure", reason="disk"}) or vector(0)'
$DebugLogBytesQuery = 'max(setlog_render_debug_log_bytes{job="setlog"}) or vector(0)'

function Get-Incident3Metrics {
    Start-Sleep -Seconds (Get-IncidentScrapeWaitSeconds)

    $renderTotalAfter = Get-PrometheusNumber -Name "render_total" -Query $RenderTotalQuery
    $renderDiskFailureAfter = Get-PrometheusNumber -Name "render_disk_failure_total" -Query $RenderDiskFailureQuery
    $renderTotalDelta = [Math]::Max(0, $renderTotalAfter - $script:RenderTotalBefore)
    $renderDiskFailureDelta = [Math]::Max(0, $renderDiskFailureAfter - $script:RenderDiskFailureBefore)
    $renderDiskFailureRatio = 0.0
    if ($renderTotalDelta -gt 0) {
        $renderDiskFailureRatio = $renderDiskFailureDelta / $renderTotalDelta
    }

    return @{
        RenderDiskFailureRatio = $renderDiskFailureRatio
        RenderDiskFailureDelta = $renderDiskFailureDelta
        DebugLogBytes = Get-PrometheusNumber -Name "debug_log_bytes" -Query $DebugLogBytesQuery
    }
}

$baseArgs = @("-Count", $BaselineCount)
$faultArgs = @()
$incidentArgs = @("-Count", $IncidentCount, "-SleepSeconds", $IncidentSleepSeconds, "-RenderEvery", 1, "-AllowFailures")

if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
    $baseArgs += @("-BaseUrl", $BaseUrl)
    $faultArgs += @("-BaseUrl", $BaseUrl)
    $incidentArgs += @("-BaseUrl", $BaseUrl)
}

Write-Host "preparing Incident 3 with baseline SetLog traffic"
& "$PSScriptRoot/baseline-traffic.ps1" @baseArgs

if (Test-IncidentValidationEnabled) {
    $script:RenderTotalBefore = Get-PrometheusNumber -Name "render_total_before" -Query $RenderTotalQuery
    $script:RenderDiskFailureBefore = Get-PrometheusNumber -Name "render_disk_failure_before" -Query $RenderDiskFailureQuery
} else {
    $script:RenderTotalBefore = 0.0
    $script:RenderDiskFailureBefore = 0.0
}

Write-Host "starting Incident 3: disk pressure drill"
& "$PSScriptRoot/fault-disk.ps1" @faultArgs

Write-Host "generating bounded render traffic while Incident 3 is active"
& "$PSScriptRoot/baseline-traffic.ps1" @incidentArgs

Write-Host "Incident 3 is active. Open Grafana and complete the incident table."
if (Test-IncidentValidationEnabled) {
    $metrics = Get-Incident3Metrics
    Assert-IncidentGe -Name "renderDiskFailureRatio" -Value $metrics.RenderDiskFailureRatio -Threshold 0.2
    Assert-IncidentGt -Name "renderDiskFailureDelta" -Value $metrics.RenderDiskFailureDelta -Threshold 0
    Assert-IncidentGt -Name "debugLogBytes" -Value $metrics.DebugLogBytes -Threshold 0
    Write-IncidentSummary @{
        incident = 3
        passed = $true
        renderDiskFailureRatio = $metrics.RenderDiskFailureRatio
        renderDiskFailureDelta = $metrics.RenderDiskFailureDelta
        debugLogBytes = $metrics.DebugLogBytes
    }
} else {
    Write-IncidentSummary @{
        incident = 3
        passed = $true
        validationSkipped = $true
    }
}
