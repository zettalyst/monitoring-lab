[CmdletBinding()]
param(
    [string] $BaseUrl,
    [System.Nullable[int]] $DiskMegabytes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/lab-common.ps1"

$BaseUrl = Get-LabString -Value $BaseUrl -EnvName "BASE_URL" -Default "http://localhost:8080"
$DiskMegabytes = Get-LabInt -Value $DiskMegabytes -EnvName "DISK_MEGABYTES" -Default 90

Invoke-LabRequest `
    -Operation "enable disk fault" `
    -Method "Post" `
    -Uri "$BaseUrl/internal/faults/disk" `
    -Body @{ enabled = $true; megabytes = $DiskMegabytes }
