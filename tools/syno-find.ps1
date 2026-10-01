# Finds the DS220+ on the local LAN by its MAC addresses.
# Read only: a ping sweep of the local /24, then the ARP table is searched for the MACs.
# If the box comes up with a static address outside the local /24, use -Static: it adds a
# temporary /32 address and a /32 route to reach it (run as administrator; -Undo removes them).
#
#   .\syno-find.ps1 -Mac 00-00-5E-00-53-01,00-00-5E-00-53-02
#   .\syno-find.ps1 -Static -NasIp 192.0.2.10 -LocalIp 192.0.2.249
#   .\syno-find.ps1 -Undo -NasIp 192.0.2.10 -LocalIp 192.0.2.249
#
# The MACs are on the label on the back of the box (LAN1 and LAN2).
param(
    [string[]]$Mac = @(),
    [string]$Interface = 'Ethernet',
    [string]$NasIp = '',
    [string]$LocalIp = '',
    [switch]$Static,
    [switch]$Undo
)

$Mac = $Mac | ForEach-Object { $_.ToUpper().Replace(':', '-') }

if ($Undo -or $Static) {
    if (-not $NasIp -or -not $LocalIp) { throw '-NasIp and -LocalIp are required with -Static and -Undo' }
}

if ($Undo) {
    Remove-NetRoute -DestinationPrefix "$NasIp/32" -InterfaceAlias $Interface -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetIPAddress -IPAddress $LocalIp -Confirm:$false -ErrorAction SilentlyContinue
    'removed'
    return
}

if ($Static) {
    # /32 only, so existing routes to the wider network are not touched
    New-NetIPAddress -InterfaceAlias $Interface -IPAddress $LocalIp -PrefixLength 32 -SkipAsSource $true | Out-Null
    New-NetRoute -DestinationPrefix "$NasIp/32" -InterfaceAlias $Interface -NextHop 0.0.0.0 -RouteMetric 1 | Out-Null
    Start-Sleep -Milliseconds 500
    # SkipAsSource: Windows never picks this address on its own, so the source must be
    # given explicitly (ping -S, ssh -b $LocalIp).
    ping.exe -n 2 -S $LocalIp $NasIp
    Get-NetNeighbor -IPAddress $NasIp -ErrorAction SilentlyContinue | Select-Object IPAddress, LinkLayerAddress, State
    return
}

if (-not $Mac) { throw '-Mac is required (the two MACs from the label, LAN1 and LAN2)' }

$addr = (Get-NetIPAddress -InterfaceAlias $Interface -AddressFamily IPv4 | Where-Object PrefixLength -eq 24 | Select-Object -First 1).IPAddress
$net  = $addr -replace '\.\d+$', ''
"ping sweep: $net.0/24"
$pings = 1..254 | ForEach-Object {
    $p = New-Object System.Net.NetworkInformation.Ping
    $p.SendPingAsync("$net.$_", 400)
}
[System.Threading.Tasks.Task]::WaitAll($pings) | Out-Null

$found = Get-NetNeighbor -InterfaceAlias $Interface -AddressFamily IPv4 |
    Where-Object { $Mac -contains $_.LinkLayerAddress.ToUpper() }
if ($found) {
    $found | Select-Object IPAddress, LinkLayerAddress, State
} else {
    'not found on the local /24; if the box has a static address elsewhere, try -Static'
}
