[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $IgnoredArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Error "fault-saturation is deprecated because it enables CPU and disk faults together. Use scripts/fault-cpu.ps1 for Incident 4 CPU pressure or scripts/fault-disk.ps1 for Incident 3 disk pressure."
exit 1
