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
$IncidentCount = Get-LabInt -Value $IncidentCount -EnvName "INCIDENT_COUNT" -Default 30
$IncidentSleepSeconds = Get-LabDouble -Value $IncidentSleepSeconds -EnvName "INCIDENT_SLEEP_SECONDS" -Default 0.2
$ValidationWindow = Get-IncidentValidationWindow

$ApiTotalQuery = 'sum(http_server_requests_seconds_count{job="setlog", uri=~"/api/.*"}) or vector(0)'
$Api5xxQuery = 'sum(http_server_requests_seconds_count{job="setlog", uri=~"/api/.*", status=~"5.."}) or vector(0)'
$ClipFailureQuery = 'sum(setlog_clip_uploads_total{job="setlog", result="failure"}) or vector(0)'
$MysqlExporterUpMinQuery = "min_over_time(up{job=`"mysqld-exporter`"}[$ValidationWindow])"
$SetlogUpQuery = 'min(up{job="setlog"})'

function Get-Incident2Metrics {
    Start-Sleep -Seconds (Get-IncidentScrapeWaitSeconds)

    $apiTotalAfter = Get-PrometheusNumber -Name "api_total" -Query $ApiTotalQuery
    $api5xxAfter = Get-PrometheusNumber -Name "api_5xx" -Query $Api5xxQuery
    $clipFailureAfter = Get-PrometheusNumber -Name "clip_failure_total" -Query $ClipFailureQuery
    $apiTotalDelta = [Math]::Max(0, $apiTotalAfter - $script:ApiTotalBefore)
    $api5xxDelta = [Math]::Max(0, $api5xxAfter - $script:Api5xxBefore)
    $clipFailureDelta = [Math]::Max(0, $clipFailureAfter - $script:ClipFailureBefore)
    $errorRatio = 0.0
    if ($apiTotalDelta -gt 0) {
        $errorRatio = $api5xxDelta / $apiTotalDelta
    }

    return @{
        ErrorRatio = $errorRatio
        ClipFailureDelta = $clipFailureDelta
        MysqlExporterUpMin = Get-PrometheusNumber -Name "mysql_exporter_up_min" -Query $MysqlExporterUpMinQuery
        SetlogUp = Get-PrometheusNumber -Name "setlog_up" -Query $SetlogUpQuery
    }
}

$baseArgs = @("-Count", $BaselineCount)
$faultArgs = @()
$incidentArgs = @("-Count", $IncidentCount, "-SleepSeconds", $IncidentSleepSeconds, "-AllowFailures")

if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
    $baseArgs += @("-BaseUrl", $BaseUrl)
    $incidentArgs += @("-BaseUrl", $BaseUrl)
}

Write-Host "preparing Incident 2 with baseline SetLog traffic"
& "$PSScriptRoot/baseline-traffic.ps1" @baseArgs

if (Test-IncidentValidationEnabled) {
    $script:ApiTotalBefore = Get-PrometheusNumber -Name "api_total_before" -Query $ApiTotalQuery
    $script:Api5xxBefore = Get-PrometheusNumber -Name "api_5xx_before" -Query $Api5xxQuery
    $script:ClipFailureBefore = Get-PrometheusNumber -Name "clip_failure_before" -Query $ClipFailureQuery
} else {
    $script:ApiTotalBefore = 0.0
    $script:Api5xxBefore = 0.0
    $script:ClipFailureBefore = 0.0
}

Write-Host "starting Incident 2: error increase drill"
& "$PSScriptRoot/fault-errors.ps1" @faultArgs

Write-Host "generating bounded failing traffic while Incident 2 is active"
& "$PSScriptRoot/baseline-traffic.ps1" @incidentArgs

Write-Host "Incident 2 is active. Open Grafana and complete the incident table."
if (Test-IncidentValidationEnabled) {
    $metrics = Get-Incident2Metrics
    Assert-IncidentGe -Name "errorRatio" -Value $metrics.ErrorRatio -Threshold 0.05
    Assert-IncidentGt -Name "clipFailureDelta" -Value $metrics.ClipFailureDelta -Threshold 0
    Assert-IncidentEq -Name "mysqlExporterUpMin" -Value $metrics.MysqlExporterUpMin -Expected 0
    Assert-IncidentEq -Name "setlogUp" -Value $metrics.SetlogUp -Expected 1
    Write-IncidentSummary @{
        incident = 2
        passed = $true
        errorRatio = $metrics.ErrorRatio
        clipFailureDelta = $metrics.ClipFailureDelta
        mysqlExporterUpMin = $metrics.MysqlExporterUpMin
        setlogUp = $metrics.SetlogUp
    }
} else {
    Write-IncidentSummary @{
        incident = 2
        passed = $true
        validationSkipped = $true
    }
}
