[CmdletBinding()]
param(
    [string] $BaseUrl,
    [System.Nullable[int]] $Count,
    [System.Nullable[double]] $SleepSeconds,
    [System.Nullable[int]] $RenderEvery,
    [switch] $AllowFailures
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/lab-common.ps1"

$BaseUrl = Get-LabString -Value $BaseUrl -EnvName "BASE_URL" -Default "http://localhost:8080"
$Count = Get-LabInt -Value $Count -EnvName "COUNT" -Default 480
$SleepSeconds = Get-LabDouble -Value $SleepSeconds -EnvName "SLEEP_SECONDS" -Default 0.03
$RenderEvery = Get-LabInt -Value $RenderEvery -EnvName "RENDER_EVERY" -Default 4
$allowFailureEnv = [Environment]::GetEnvironmentVariable("ALLOW_FAILURES")
$allowFailuresEnabled = $AllowFailures.IsPresent -or $allowFailureEnv -in @("1", "true", "TRUE")

if ($Count -lt 1) {
    throw "Count must be a positive integer, got: $Count"
}

if ($SleepSeconds -lt 0) {
    throw "SleepSeconds must be zero or greater, got: $SleepSeconds"
}

if ($RenderEvery -lt 0) {
    throw "RenderEvery must be zero or greater, got: $RenderEvery"
}

function Invoke-TrafficRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Operation,
        [Parameter(Mandatory = $true)]
        [string] $Method,
        [Parameter(Mandatory = $true)]
        [string] $Uri,
        [object] $Body = $null
    )

    try {
        return Invoke-LabRequest -Operation $Operation -Method $Method -Uri $Uri -Body $Body
    } catch {
        if ($allowFailuresEnabled) {
            Write-Warning ("request failed during {0}; continuing because failures are allowed" -f $Operation)
            return $null
        }

        throw
    }
}

$roomProbeRequired = $false
$roomResponse = Invoke-TrafficRequest -Operation "create room" -Method "Post" -Uri "$BaseUrl/api/rooms"
$roomId = $null
try {
    if ($null -ne $roomResponse) {
        $roomId = [string] $roomResponse.roomId
    }
} catch {
    $roomId = $null
}

if ([string]::IsNullOrWhiteSpace($roomId)) {
    if ($allowFailuresEnabled) {
        Write-Warning "failed to create or parse roomId; using synthetic room id because failures are allowed"
        $roomProbeRequired = $true
        $roomId = "room-outage-drill"
    } else {
        $rawResponse = $roomResponse | ConvertTo-Json -Compress
        throw "failed to parse roomId from /api/rooms response: $rawResponse"
    }
}

for ($i = 1; $i -le $Count; $i++) {
    if ($roomProbeRequired) {
        $probeResponse = Invoke-TrafficRequest `
            -Operation "create room probe during iteration $i" `
            -Method "Post" `
            -Uri "$BaseUrl/api/rooms"

        $probeRoomId = $null
        try {
            if ($null -ne $probeResponse) {
                $probeRoomId = [string] $probeResponse.roomId
            }
        } catch {
            $probeRoomId = $null
        }

        if (-not [string]::IsNullOrWhiteSpace($probeRoomId)) {
            $roomId = $probeRoomId
            $roomProbeRequired = $false
            Write-Warning "adopted recovered roomId $roomId during create room probe iteration $i"
        } else {
            Write-Warning "create room probe during iteration $i did not return a roomId; keeping synthetic room id"
        }
    }

    Invoke-TrafficRequest `
        -Operation "create clip during iteration $i" `
        -Method "Post" `
        -Uri "$BaseUrl/api/clips" `
        -Body @{ roomId = $roomId; networkType = "wifi" } | Out-Null

    if (($RenderEvery -gt 0) -and (($i % $RenderEvery) -eq 0)) {
        Invoke-TrafficRequest `
            -Operation "create render job during iteration $i" `
            -Method "Post" `
            -Uri "$BaseUrl/api/render-jobs" `
            -Body @{ roomId = $roomId } | Out-Null
    }

    Invoke-TrafficRequest `
        -Operation "fetch feed during iteration $i" `
        -Method "Get" `
        -Uri "$BaseUrl/api/feed" | Out-Null

    Start-Sleep -Milliseconds ([int] ($SleepSeconds * 1000))
}

Write-Output ("sent {0} baseline iterations to {1} with room {2}" -f $Count, $BaseUrl, $roomId)
