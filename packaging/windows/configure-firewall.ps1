[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AgentPath,
    [Parameter(Mandatory = $true)][string]$RuleName,
    [Parameter(Mandatory = $true)][ValidateSet('Enable', 'Disable', 'Validate', 'ValidateNetwork')][string]$Mode
)

$ErrorActionPreference = 'Stop'
$AgentPath = (Resolve-Path -LiteralPath $AgentPath).Path

function Get-UnmanagedInboundAllowRules {
    @(
        Get-NetFirewallApplicationFilter -Program $AgentPath -ErrorAction SilentlyContinue |
            ForEach-Object {
                Get-NetFirewallRule -AssociatedNetFirewallApplicationFilter $_ -ErrorAction SilentlyContinue
            } |
            Where-Object {
                $_.Enabled -eq 'True' -and
                $_.Direction -eq 'Inbound' -and
                $_.Action -eq 'Allow' -and
                $_.DisplayName -ne $RuleName
            }
    )
}

function Remove-UnmanagedInboundAllowRules {
    foreach ($rule in @(Get-UnmanagedInboundAllowRules)) {
        Remove-NetFirewallRule -Name $rule.Name -ErrorAction Stop
    }
}

if ($Mode -eq 'ValidateNetwork') {
    $routeCandidates = @(
        Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Where-Object { $_.State -eq 'Alive' -and $_.NextHop -ne '0.0.0.0' } |
            ForEach-Object {
                $route = $_
                $ipInterface = Get-NetIPInterface -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
                if ($ipInterface -and $ipInterface.ConnectionState -eq 'Connected') {
                    [pscustomobject]@{
                        InterfaceIndex = $route.InterfaceIndex
                        Metric = ([int]$route.RouteMetric + [int]$ipInterface.InterfaceMetric)
                    }
                }
            } |
            Sort-Object Metric, InterfaceIndex
    )
    if ($routeCandidates.Count -eq 0) {
        exit 1
    }
    $profiles = @(Get-NetConnectionProfile -InterfaceIndex $routeCandidates[0].InterfaceIndex -ErrorAction SilentlyContinue)
    if ($profiles.Count -eq 0 -or $profiles[0].NetworkCategory -ne 'Private') {
        exit 1
    }
    exit 0
}

if ($Mode -eq 'Validate') {
    $rules = @(Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue)
    if ($rules.Count -ne 1) {
        exit 1
    }
    $rule = $rules[0]
    $application = $rule | Get-NetFirewallApplicationFilter
    $address = $rule | Get-NetFirewallAddressFilter
    if ($rule.Enabled -ne 'True' -or
        $rule.Profile -ne 'Private' -or
        $rule.Direction -ne 'Inbound' -or
        $rule.Action -ne 'Allow' -or
        $application.Program -ne $AgentPath -or
        $address.RemoteAddress -notcontains 'LocalSubnet') {
        exit 1
    }
    if (@(Get-UnmanagedInboundAllowRules).Count -gt 0) {
        exit 1
    }
    exit 0
}

Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction Stop
Remove-UnmanagedInboundAllowRules

if ($Mode -eq 'Disable') {
    exit 0
}

$rule = New-NetFirewallRule `
    -DisplayName $RuleName `
    -Description 'Mimi Remote current-user backend, private LAN only' `
    -Direction Inbound `
    -Action Allow `
    -Enabled True `
    -Profile Private `
    -RemoteAddress LocalSubnet `
    -Program $AgentPath

$application = $rule | Get-NetFirewallApplicationFilter
$address = $rule | Get-NetFirewallAddressFilter
if ($rule.Enabled -ne 'True' -or
    $rule.Profile -ne 'Private' -or
    $application.Program -ne $AgentPath -or
    $address.RemoteAddress -notcontains 'LocalSubnet') {
    throw 'The created firewall rule did not preserve the required Private/LocalSubnet/program boundary.'
}
