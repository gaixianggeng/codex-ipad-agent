[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AgentPath,
    [Parameter(Mandatory = $true)][string]$LogPath,
    [string]$TaskName = 'Mimi Remote agentd'
)

$ErrorActionPreference = 'Stop'
$AgentPath = (Resolve-Path -LiteralPath $AgentPath).Path
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute $AgentPath -Argument "serve --managed-service --log-file `"$LogPath`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Mimi Remote current-user backend' `
    -Force | Out-Null

$registered = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
$registeredSid = ([Security.Principal.NTAccount]$registered.Principal.UserId).
    Translate([Security.Principal.SecurityIdentifier]).Value
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if ($registeredSid -ne $currentSid -or $registered.Principal.RunLevel -ne 'Limited') {
    throw "Scheduled task principal mismatch: $($registered.Principal.UserId) / $($registered.Principal.RunLevel)"
}
