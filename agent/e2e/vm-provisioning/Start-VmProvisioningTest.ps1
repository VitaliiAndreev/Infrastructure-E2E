<#
.SYNOPSIS
    Run the VM provisioning E2E test directly, without the polling agent.

.DESCRIPTION
    Bootstraps the required modules, then calls Invoke-VmProvisioningTest.
    Use this for on-demand test runs that do not need a GitHub deployment
    signal (local debugging, first-time verification).

    VmProvisionerConfig is written to the vault at runtime by
    Invoke-VmProvisioningSetup and removed in its finally block - no
    manual vault setup is required before running this script.

    Prerequisites:
      - PowerShell 7+.
      - Common.PowerShell >= 1.3.3 installed (or will be installed here).
      - Infrastructure.Secrets installed.
      - Run as Administrator (Hyper-V cmdlets require elevation).

.EXAMPLE
    # Run with all defaults: ICS-on-Internal switch named
    # ExternalSwitch-Shared, router VM pinned to 192.168.137.10
    # with gateway 192.168.137.1 (the ICS-assigned host vNIC).
    .\agent\e2e\vm-provisioning\Start-VmProvisioningTest.ps1

.EXAMPLE
    # Bridged-Ethernet External vSwitch instead of ICS - pin the
    # router to a free address on the LAN, gateway to the LAN gateway.
    .\agent\e2e\vm-provisioning\Start-VmProvisioningTest.ps1 `
        -RouterExternalIp 192.168.1.50 -RouterExternalGateway 192.168.1.1
#>

[CmdletBinding()]
param(
    # Absolute path to the Infrastructure-Vm-Provisioner repo root.
    [string] $ProvisionerPath = 'C:\a_Code\Infrastructure-Vm-Provisioner',

    # Ubuntu version to provision (router + workload VMs).
    [string] $UbuntuVersion = '24.04',

    # DNS resolver the router VM forwards downstream queries to.
    [string] $Dns = '8.8.8.8',

    # Host's External vSwitch the router's upstream NIC attaches to.
    # Created on demand if absent (bound to -ExternalAdapterName).
    [string] $ExternalSwitchName = 'ExternalSwitch-Shared',

    # Physical adapter the External vSwitch binds to when created.
    # Ignored at runtime if the switch already exists - e.g. when
    # the switch is Internal+ICS, this is purely cosmetic.
    [string] $ExternalAdapterName = 'Ethernet',

    # Static IP the router VM's ext0 gets. Pinned (not DHCP) so the
    # run does not depend on the upstream DHCP server being healthy:
    # bridged-Wi-Fi External MAC-collides via shared MAC at the AP,
    # and Internal+ICS DHCP silently breaks across Wi-Fi network
    # changes. The default
    # matches the ICS-on-Internal subnet (192.168.137.0/24) with
    # the host vNIC at .1 and the router at .10 - safely outside
    # the ICS DHCP pool (.20-.254) so a stray DHCP client cannot
    # collide.
    [string] $RouterExternalIp = '192.168.137.10',

    # Default gateway router VM uses for ext0 egress. With ICS this
    # is the host vNIC's hardcoded 192.168.137.1; with a bridged
    # Ethernet External vSwitch this should be the LAN gateway.
    [string] $RouterExternalGateway = '192.168.137.1',

    # Workstation path for Hyper-V VM config files.
    [string] $VmConfigPath = 'E:\a_VMs\Hyper-V\Config',

    # Workstation path for the test VHDX files.
    [string] $VhdPath = 'E:\a_VMs\Hyper-V\Disks',

    # Which engine installs the jdk / dotnet toolchains. 'ansible' (default)
    # drives Infrastructure-Vm-Provisioner's provision-toolchains.sh
    # (requires -WslDistro); 'custom-powershell' keeps the PowerShell
    # reconciler installing them inside provision.ps1. The same jdk / dotnet
    # assertions run for both. See Set-VmToolchainsForTest.
    [ValidateSet('custom-powershell', 'ansible')]
    [string] $ToolchainsFlow = 'ansible',

    # Which engine transports the per-VM `files` entries. 'ansible' (default)
    # drives Infrastructure-Vm-Provisioner's provision-files.sh (requires
    # -WslDistro); 'custom-powershell' keeps provision.ps1's in-line transport
    # copying them. Independent of -ToolchainsFlow, and the same file-transfer
    # assertions run for both. See Set-VmFilesForTest.
    [ValidateSet('custom-powershell', 'ansible')]
    [string] $FilesFlow = 'ansible',

    # WSL distro the Ansible bridge runs inside. Required when
    # -ToolchainsFlow or -FilesFlow is ansible; ignored otherwise. Passed via
    # `wsl -d <name>` so the run does not depend on the workstation's WSL
    # default (Docker Desktop silently moves it to its no-bash
    # 'docker-desktop' distro).
    [string] $WslDistro = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\..\Initialize-E2EEnvironment.ps1"

# Dot-source the test script after Common.PowerShell is loaded because the
# test depends on Invoke-SshClientCommand and Invoke-ModuleInstall from it.
. "$PSScriptRoot\Invoke-VmProvisioningTest.ps1"

Invoke-VmProvisioningTest -Config ([PSCustomObject]@{
    ProvisionerPath = $ProvisionerPath
    ToolchainsFlow  = $ToolchainsFlow
    FilesFlow       = $FilesFlow
    WslDistro       = $WslDistro
    TestVm          = [PSCustomObject]@{
        ubuntuVersion         = $UbuntuVersion
        dns                   = $Dns
        externalSwitchName    = $ExternalSwitchName
        externalAdapterName   = $ExternalAdapterName
        routerExternalIp      = $RouterExternalIp
        routerExternalGateway = $RouterExternalGateway
        vmConfigPath          = $VmConfigPath
        vhdPath               = $VhdPath
    }
})
