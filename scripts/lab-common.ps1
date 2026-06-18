function Get-LabString {
    param(
        [string] $Value,
        [Parameter(Mandatory = $true)]
        [string] $EnvName,
        [Parameter(Mandatory = $true)]
        [string] $Default
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    $envValue = [Environment]::GetEnvironmentVariable($EnvName)
    if (-not [string]::IsNullOrWhiteSpace($envValue)) {
        return $envValue
    }

    return $Default
}

function Get-LabInt {
    param(
        [System.Nullable[int]] $Value,
        [Parameter(Mandatory = $true)]
        [string] $EnvName,
        [Parameter(Mandatory = $true)]
        [int] $Default
    )

    if ($null -ne $Value) {
        return [int] $Value
    }

    $envValue = [Environment]::GetEnvironmentVariable($EnvName)
    if (-not [string]::IsNullOrWhiteSpace($envValue)) {
        return [int] $envValue
    }

    return $Default
}

function Get-LabDouble {
    param(
        [System.Nullable[double]] $Value,
        [Parameter(Mandatory = $true)]
        [string] $EnvName,
        [Parameter(Mandatory = $true)]
        [double] $Default
    )

    if ($null -ne $Value) {
        return [double] $Value
    }

    $envValue = [Environment]::GetEnvironmentVariable($EnvName)
    if (-not [string]::IsNullOrWhiteSpace($envValue)) {
        return [double] $envValue
    }

    return $Default
}

function Invoke-LabRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Operation,
        [Parameter(Mandatory = $true)]
        [string] $Method,
        [Parameter(Mandatory = $true)]
        [string] $Uri,
        [object] $Body = $null
    )

    $request = @{
        Method = $Method
        Uri = $Uri
        ErrorAction = "Stop"
        TimeoutSec = 30
    }

    if ($null -ne $Body) {
        $request.ContentType = "application/json"
        $request.Body = ($Body | ConvertTo-Json -Compress)
    }

    try {
        return Invoke-RestMethod @request
    } catch {
        Write-Error ("failed to {0}: {1} {2}: {3}" -f $Operation, $Method, $Uri, $_.Exception.Message) -ErrorAction Continue
        $details = $null
        if ($null -ne $_.ErrorDetails) {
            $details = $_.ErrorDetails.Message
        }
        if (-not [string]::IsNullOrWhiteSpace($details)) {
            Write-Error $details -ErrorAction Continue
        }
        throw
    }
}
