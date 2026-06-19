Set-StrictMode -Version Latest

function Get-LabBool {
    param(
        [string] $EnvName,
        [bool] $Default
    )

    $value = [Environment]::GetEnvironmentVariable($EnvName)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }

    return $value -in @("1", "true", "TRUE", "yes", "YES", "on", "ON")
}

function Get-IncidentPrometheusUrl {
    return Get-LabString -Value $null -EnvName "PROMETHEUS_URL" -Default "http://localhost:9090"
}

function Get-IncidentValidationWindow {
    return Get-LabString -Value $null -EnvName "INCIDENT_VALIDATION_WINDOW" -Default "2m"
}

function Get-IncidentScrapeWaitSeconds {
    return Get-LabDouble -Value $null -EnvName "INCIDENT_SCRAPE_WAIT_SECONDS" -Default 8
}

function Get-PrometheusValue {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Query
    )

    $prometheusUrl = Get-IncidentPrometheusUrl
    $uri = "$prometheusUrl/api/v1/query?query=$([uri]::EscapeDataString($Query))"
    $response = Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec 30
    if ($response.status -ne "success") {
        throw "Prometheus query failed: $Query"
    }

    if ($null -eq $response.data.result -or $response.data.result.Count -lt 1) {
        return $null
    }

    return [string] $response.data.result[0].value[1]
}

function Get-PrometheusNumber {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [string] $Query
    )

    $value = Get-PrometheusValue -Query $Query
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "metric $Name returned no data. Query: $Query"
    }

    $number = 0.0
    if (-not [double]::TryParse($value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref] $number)) {
        throw "metric $Name returned a non-numeric value: $value"
    }

    return $number
}

function Assert-IncidentGe {
    param([string] $Name, [double] $Value, [double] $Threshold)
    if ($Value -lt $Threshold) {
        throw "incident validation failed: $Name expected >= $Threshold, got $Value"
    }
}

function Assert-IncidentGt {
    param([string] $Name, [double] $Value, [double] $Threshold)
    if ($Value -le $Threshold) {
        throw "incident validation failed: $Name expected > $Threshold, got $Value"
    }
}

function Assert-IncidentLe {
    param([string] $Name, [double] $Value, [double] $Threshold)
    if ($Value -gt $Threshold) {
        throw "incident validation failed: $Name expected <= $Threshold, got $Value"
    }
}

function Assert-IncidentEq {
    param([string] $Name, [double] $Value, [double] $Expected)
    if ($Value -ne $Expected) {
        throw "incident validation failed: $Name expected == $Expected, got $Value"
    }
}

function Write-IncidentSummary {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Summary
    )

    $Summary | ConvertTo-Json -Compress
}

