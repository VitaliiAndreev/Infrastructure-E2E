<#
.NOTES
    Do not run this file directly. Dot-source it after Common.PowerShell
    and Infrastructure.Secrets are loaded (Start-E2EAgent.ps1 handles this
    via Invoke-RunnerLifecycleTest -> Invoke-VmUsersTest -> this file).
#>

# Posh-SSH is loaded for its bundled Renci.SshNet.dll. Posh-SSH's own
# cmdlets are not used - ConnectionInfoGenerator in Posh-SSH 3.x drops
# algorithm entries, breaking KEX against OpenSSH 9.x (Ubuntu 24.04).
# SSH.NET is used directly via Invoke-SshClientCommand (Common.PowerShell).
Invoke-ModuleInstall -ModuleName 'Posh-SSH'

# Assertion helpers. Each lives in its own file so they can be unit-tested in
# isolation and so this file stays focused on setup/teardown/orchestration.
# Files are grouped into subfolders by role and domain:
#   - assertions\jdk\        : reconciler assertions for javaDevKit
#   - assertions\dotnet\     : reconciler assertions for dotnetSdk + dotnetTools
#   - assertions\toolchains\ : Ansible-engine assertions for the sections 2/3
#                              'toolchains' taxonomy block (apt + docker)
#   - assertions\files\      : reconciler assertions for the 'files' field
#   - assertions\env-vars\   : reconciler assertions for the 'envVars' field
#   - assertions\network\    : VM/router readiness, netplan, egress
#   - assertions\lifecycle\  : VM teardown verification + stale-VM guard
#   - phases\                : phase orchestrators + teardown (dot-sourced below)
#   - diag\                  : pre-teardown runtime snapshot (dot-sourced from
#                              phases\Invoke-VmProvisioningTeardown.ps1)
. "$PSScriptRoot\assertions\lifecycle\Invoke-NoLeftoverTestVmsAssertions.ps1"
. "$PSScriptRoot\assertions\network\Invoke-VmReadyAssertions.ps1"
. "$PSScriptRoot\assertions\network\Invoke-StaticNetworkAssertions.ps1"
. "$PSScriptRoot\assertions\network\Invoke-EgressAssertions.ps1"
. "$PSScriptRoot\assertions\network\Get-EgressFailureDiagnostics.ps1"
. "$PSScriptRoot\assertions\jdk\Invoke-JdkInstallAssertions.ps1"
. "$PSScriptRoot\assertions\jdk\Invoke-JdkUninstallAssertions.ps1"
. "$PSScriptRoot\assertions\jdk\Invoke-JdkNoopAssertions.ps1"
. "$PSScriptRoot\assertions\jdk\Invoke-JdkVersionChangeAssertions.ps1"
. "$PSScriptRoot\assertions\jdk\Invoke-NoJdkVmAssertions.ps1"
. "$PSScriptRoot\assertions\dotnet\Invoke-DotnetSdkInstallAssertions.ps1"
. "$PSScriptRoot\assertions\dotnet\Invoke-DotnetSdkUninstallAssertions.ps1"
. "$PSScriptRoot\assertions\dotnet\Invoke-DotnetSdkNoopAssertions.ps1"
. "$PSScriptRoot\assertions\dotnet\Invoke-DotnetSdkVersionChangeAssertions.ps1"
. "$PSScriptRoot\assertions\dotnet\Invoke-DotnetToolsAssertions.ps1"
. "$PSScriptRoot\assertions\dotnet\Invoke-NoDotnetSdkVmAssertions.ps1"
. "$PSScriptRoot\assertions\powershell\Invoke-PowerShellInstallAssertions.ps1"
. "$PSScriptRoot\assertions\toolchains\Invoke-ToolchainAptInstallAssertions.ps1"
. "$PSScriptRoot\assertions\toolchains\Invoke-ToolchainBatsLibsInstallAssertions.ps1"
. "$PSScriptRoot\assertions\toolchains\Invoke-DockerInstallAssertions.ps1"
. "$PSScriptRoot\assertions\toolchains\Invoke-NoToolchainsVmAssertions.ps1"
. "$PSScriptRoot\assertions\files\Invoke-FileTransferAssertions.ps1"
. "$PSScriptRoot\assertions\files\Invoke-BulkFileTransferAssertions.ps1"
. "$PSScriptRoot\assertions\env-vars\Invoke-EnvVarsAppliedAssertions.ps1"
. "$PSScriptRoot\assertions\env-vars\Invoke-EnvVarsRemovedAssertions.ps1"
. "$PSScriptRoot\Resolve-RouterIpFromKvp.ps1"
# Engine dispatchers (custom-powershell in-line path vs the Ansible
# provision-files.sh / provision-toolchains.sh drivers). Dot-sourced before the
# phase files so they can call both. Files first, matching the order the phases
# call them in. Each pulls in the shared Invoke-VmProvisionerAnsibleOps itself.
. "$PSScriptRoot\Set-VmFilesForTest.ps1"
. "$PSScriptRoot\Set-VmToolchainsForTest.ps1"
# Shell-out timing wrapper (feature 88 C2). Phase 1 wraps its toolchains
# shell-out in a nested child-process span (feature 88 E2), so the helper
# must be loaded before the phase files below. Dot-sourced here - the lowest
# layer that consumes it - so the standalone provisioning flow resolves it
# too; the users / runner-lifecycle chains inherit it through this file.
. "$PSScriptRoot\..\timing\Measure-ChildProcessTimingSpan.ps1"

# ---------------------------------------------------------------------------
# Test scenario constants
#
# The provisioning E2E runs as a four-phase scenario over two VMs so the
# install / uninstall / re-install / deprovision lifecycle is covered in one
# run. VM identities are pinned for the whole scenario - only VM1's
# javaDevKit block changes between phases. See
# docs/dev/implementation/06 - jdk uninstall flag/plan.md (step 4) for the
# decisions behind this shape.
#
# VM2 carries no javaDevKit in any phase - it is the "blast-radius witness"
# that proves a JDK step on VM1 cannot leak to VM2 in the same provision run.
#
# Declared at script scope BEFORE the phase / verification files are
# dot-sourced because those files reference these via $script:*.
# ---------------------------------------------------------------------------
$script:Vm1Name             = 'e2e-test-1'
$script:Vm2Name             = 'e2e-test-2'

# Router-VM scenario shape. Every workload batch in the post-feature-53
# topology requires exactly one router VM on the same private switch; the
# router carries the gateway IP downstream VMs route through. We mint
# the router once at Setup time and keep it in every phase's
# VmProvisionerConfig so the provisioner's reconcile path takes the
# "existing VM" branch on phases 2 and 3 instead of trying to re-create
# it. Workload IPs are pinned internal to the test (10.99.0.10 / .11);
# only the router's upstream NIC IP is operator-supplied via
# $Config.TestVm.routerExternalIp.
$script:RouterVmName        = 'router-e2e'
$script:RouterUsername      = 'routeradmin'
$script:PrivateSwitchName   = 'PrivateSwitch-E2E'
$script:RouterPrivateIp     = '10.99.0.1'
$script:PrivateSubnetMask   = '24'
$script:Vm1Ip               = '10.99.0.10'
$script:Vm2Ip               = '10.99.0.11'

# Router VmProvisionerConfig entry, minted in Invoke-VmProvisioningSetup.
# Stashed at script scope so Write-VmProvisionerConfig can prepend it to
# every phase's array - the per-phase functions only describe workload
# state. The router credential is generated once at Setup and never
# rewritten; phases 2 and 3 rewrite the config but the router's row
# stays byte-identical so the reconciler sees it as unchanged.
$script:RouterEntry = $null

# JDK pins. Two distinct major versions so the reconciler must observably
# uninstall the old dir on a version change (different /opt/jdk-temurin-*
# dir, different java -version prefix). Used across the scenarios:
#   - Phase 1   : install   $JdkInitialVersion
#   - Phase 2a  : drop field (uninstall via absent)
#   - Phase 2b  : reinstall $JdkReinstallVersion
#   - Phase 3a  : version change   $JdkReinstallVersion -> $JdkInitialVersion
#   - Phase 3b  : remove via @()   (uninstall via empty list)
$script:JdkTestVendor       = 'temurin'
$script:JdkInitialVersion   = '21'
$script:JdkReinstallVersion = '17'
$script:JdkInstallPrefix    = "/opt/jdk-$script:JdkTestVendor-"

# Snapshot captured by phase 1 after the install assertions pass and
# consumed by the phase-1 no-op rerun assertion. Declared here (not
# inside Phase 1) so it survives the dot-source / function-scope
# boundary.
$script:Phase1JdkSnapshot = $null

# .NET SDK pins. Two distinct major.minor channels so the version-change
# phase observably swaps install dirs and manifests. Exact resolved
# version strings so the install assertion can require equality against
# 'dotnet --version' (the resolver always lands on a feature-band build,
# unlike JDK where the resolver expands '21' to '21.0.6+7' and the
# assertion does a prefix match).
#   - Phase 1   : install   $DotnetInitialResolvedVersion
#   - Phase 2a  : dotnetSdk=$null (uninstall via explicit null)
#   - Phase 2b  : reinstall $DotnetReinstallResolvedVersion
#   - Phase 3a  : version change $DotnetReinstallResolvedVersion -> $DotnetInitialResolvedVersion
#   - Phase 3b  : remove via @() (uninstall via empty list)
# 8.0.100 and 9.0.100 are both released GA SDK builds Microsoft has
# committed to permanently - safe to pin against the live release
# metadata feed.
$script:DotnetInitialChannel           = '8.0'
$script:DotnetInitialResolvedVersion   = '8.0.100'
$script:DotnetReinstallChannel         = '9.0'
$script:DotnetReinstallResolvedVersion = '9.0.100'
$script:DotnetInstallPrefix            = '/opt/dotnet-'

# Ansible-engine on-disk layout. Under ToolchainsFlow=ansible the
# Common-Ansible toolchain_host_push roles install the JDK to /opt/jdk-<v>
# (no vendor infix) and write their manifests to a different store with
# different filename prefixes than the PowerShell reconciler. The phases
# feed these to the engine-parameterized assertions (step 5.5-A.5) so the
# same end-state checks run against whichever engine placed the toolchain.
# The .NET SDK install prefix (/opt/dotnet-) is identical across engines,
# so it is reused from $script:DotnetInstallPrefix rather than redeclared.
$script:AnsibleJdkInstallPrefix   = '/opt/jdk-'
$script:AnsibleManifestStoreDir   = '/var/lib/common-ansible/toolchains/manifests'
$script:AnsibleJdkManifestPrefix  = 'jdk-'
$script:AnsibleSdkManifestPrefix  = 'dotnet-'
$script:AnsibleToolManifestPrefix = 'dotnettool-'

# Snapshot captured by phase 1 after the dotnet install assertions pass
# and consumed by the phase-1 no-op rerun assertion. Symmetric with
# Phase1JdkSnapshot.
$script:Phase1DotnetSnapshot = $null

# .NET global-tool pins. One real tool (dotnet-reportgenerator-globaltool)
# is co-tenanted on VM1 across phases 1-3 to exercise the
# DotnetToolsProvider end-to-end against a real nuget.org round-trip.
# Two distinct minor releases so phase 3a's version-change is observably
# a swap of .store/{id}/{version}/ rather than a no-op.
#
# The tool is installed in phase 1 alongside dotnetSdk 8.0.100, removed
# (via the SDK uninstall walker) in phase 2a, reinstalled in phase 2b
# alongside dotnetSdk 9.0.100, version-changed in phase 3a, and fully
# torn down in phase 3b.
#
# reportgenerator targets net8.0/net9.0 multi-target so both SDK pins
# above are compatible. The pinned versions are released GA NuGet
# builds Microsoft cannot retract retroactively.
$script:DotnetToolId               = 'dotnet-reportgenerator-globaltool'
$script:DotnetToolInitialVersion   = '5.4.4'
$script:DotnetToolReinstallVersion = '5.4.5'
$script:DotnetToolCommand          = 'reportgenerator'

# Sections 2 and 3 of the toolchain taxonomy - the optional `toolchains` block
# on a VM's config entry, consumed only by the Ansible engine (the PowerShell
# reconciler has no section-2/3 concept, so the phases author this block and
# assert it under ToolchainsFlow=ansible only).
#
# Section 2 ("vm-downloaded"): apt packages the VM pulls from its own archive,
# with exact apt pins so a re-provision converges on a known build rather than
# whatever the archive currently offers. These two are the ci-bash toolchain the
# production runner declares, so the E2E exercises the real-world package set.
# The pins are the Ubuntu 24.04 archive versions; they move with the base image,
# not with this test.
#
# Each entry carries its own smoke recipe alongside the pin so
# Invoke-ToolchainAptInstallAssertions can prove the binary runs without holding
# per-tool knowledge itself:
#   - shellcheck reports its version, so the smoke doubles as a pin cross-check.
#     The pattern matches only the upstream part: the apt pin's '-1' Debian
#     revision suffix is packaging metadata the tool itself never prints.
#   - bats is a harness, not a versioned utility - "it runs a test file" is the
#     property that matters, so its recipe writes a trivial .bats and runs it.
#     --tap forces the machine-readable formatter; without it bats picks pretty
#     vs tap from whether stdout is a terminal, which SSH would make ambiguous.
#
# This list is the single source of truth for the scenario: the config block
# written to VmProvisionerConfig is projected from it by
# New-ToolchainsTaxonomyBlock (see Internal helpers), and the same objects are
# passed to the install and witness assertions - so a declared package can never
# drift out of step with what is asserted.
$script:ToolchainAptPackages = @(
    [PSCustomObject]@{
        Name         = 'shellcheck'
        Version      = '0.9.0-1'
        Command      = 'shellcheck'
        SmokeCommand = 'shellcheck --version'
        SmokePattern = 'version:\s*0\.9\.0'
    },
    [PSCustomObject]@{
        Name         = 'bats'
        Version      = '1.10.0-1'
        Command      = 'bats'
        SmokeCommand = 'printf ''@test "smoke" {\n  true\n}\n'' > ' +
                       '/tmp/e2e-bats-smoke.bats && bats --tap ' +
                       '/tmp/e2e-bats-smoke.bats'
        SmokePattern = 'ok 1'
    }
)

# Section 2 ("vm-downloaded"), batsLibs mechanism: the bats helper libraries
# apt cannot serve, fetched from bats-core GitHub tag tarballs and baked by the
# toolchain_bats_libs role. bats-support + bats-assert are the common pair
# (assert depends on support at load time); the pins are the tags the role
# installs. Consumed by New-ToolchainsTaxonomyBlock (projected into
# vmDownloaded.batsLibs) and by Invoke-ToolchainBatsLibsInstallAssertions.
$script:ToolchainBatsLibs = @(
    [PSCustomObject]@{ Name = 'bats-support'; Version = '0.3.0' }
    [PSCustomObject]@{ Name = 'bats-assert';  Version = '2.1.0' }
)

# Section 3 ("base-image"): a presence gate, not a version list - a `docker`
# entry switches on the whole-daemon install. Named as a constant so the config
# projection below and any future gate check read one source.
$script:ToolchainBaseImageDocker = 'docker'

# PowerShell (section 1, host-pushed). An EXACT version: unlike javaDevKit and
# dotnetSdk, the powershell role composes its archive name from the version and
# rejects a loose pin, so the host-side staging step is what turns an
# operator's '7.6' into a concrete build. Declaring the concrete build here
# means the E2E asserts the same string end to end - config, staged tarball
# name, and what the running interpreter reports.
#
# Ansible-engine only: the custom-powershell reconciler has no PowerShell
# provider, so phase 1 gates both the config entry and its assertions on the
# engine, the same way it gates the section-2/3 taxonomy block.
$script:PowerShellVersion = '7.6.4'

# The apt package supplying ICU on the target's Ubuntu 24.04. NOT declared in
# the VM's section-2 apt list: the powershell role installs it itself as a hard
# prerequisite (pwsh cannot start without ICU, and the stock image ships none).
# It is named here only so the assertion can prove the role did so, rather than
# the E2E quietly satisfying the dependency on the role's behalf and testing
# nothing.
$script:PowerShellIcuPackage = 'libicu74'

# File-transfer fixture. Resolved from $PSScriptRoot so the absolute path is
# computed on whichever workstation runs the test rather than being hard-
# coded. The target lives under /opt/e2e-fixtures/ so it does not collide
# with any real provisioner-managed path. Exercised in phases 1 and 2 on
# VM1 - phase 1 covers initial Copy-VmFiles dispatch alongside the JDK
# install, phase 2 covers the idempotence guarantee on re-provision.
$script:FileTransferSource = Join-Path $PSScriptRoot 'fixtures\file-transfer-fixture.txt'
$script:FileTransferTarget = '/opt/e2e-fixtures/file-transfer-fixture.txt'

# Bulk-file (pattern) fixture. Three tiny .jar files with distinguishable
# content land under /opt/ci-jars via Copy-VmFilesByPattern. Mirrors the
# CI-classpath use case that motivated the bulk form. Phase 1 places them,
# phase 2 re-provisions to assert idempotence. Basenames are the
# discriminator the assertions match against; their contents differ so a
# partial-copy bug surfaces as a per-file SHA-256 mismatch naming the
# offender.
$script:BulkFileTransferSourceDir = Join-Path $PSScriptRoot 'fixtures\jars'
$script:BulkFileTransferPattern   = Join-Path $PSScriptRoot 'fixtures\jars\*.jar'
$script:BulkFileTransferTargetDir = '/opt/ci-jars'
$script:BulkFileTransferBaseNames = @('a.jar', 'b.jar', 'c.jar')

# envVars fixture. Single managed block 'e2e-ci' carried across all
# three phases on VM1: phase 1 writes two entries, phase 2 narrows to
# one, phase 3 sets entries:[] to exercise block removal. The
# MARKER_OUTSIDE line is seeded by phase 1 AFTER its first
# provision.ps1 returns (the VM does not exist before that) and is
# checked by phases 2 and 3 to prove lines outside the managed block
# survive re-writes and removal. See
# docs/dev/implementation/08 - env vars/plan.md step 5 for the
# decisions behind this shape.
$script:EnvVarsBlockName  = 'e2e-ci'
$script:EnvVarsFooHome    = [PSCustomObject]@{ Name = 'FOO_HOME'; Value = '/opt/foo' }
$script:EnvVarsBarVar     = [PSCustomObject]@{ Name = 'BAR_VAR';  Value = 'baz' }
$script:EnvVarsMarkerName = 'MARKER_OUTSIDE'
$script:EnvVarsMarkerLine = "$($script:EnvVarsMarkerName)=`"untouched`""

# Phase 2's E6 assertion compares /etc/environment's mtime against this
# snapshot, taken at the end of phase 1 AFTER the marker is seeded so
# the seed write itself does not leak into the "did the transport
# rewrite the block?" signal.
$script:EnvVarsPhase1Mtime = $null

# ---------------------------------------------------------------------------
# Internal helpers
#
# Stay in this file (rather than in their own Public-style files) because
# they are orchestrator-level glue: each is used by multiple phases and
# none of them are independently meaningful outside the four-phase
# scenario this module defines.
# ---------------------------------------------------------------------------

# 18 random bytes -> 24-char base64. Strong enough for an ephemeral test VM;
# never stored anywhere except the VmProvisioner vault for the test duration.
function New-VmProvisioningPassword {
    return [Convert]::ToBase64String(
        [Security.Cryptography.RandomNumberGenerator]::GetBytes(18))
}

# Builds the common workload-VM entry shape. The javaDevKit and files
# blocks are layered on top by callers so each phase can compose the
# entry it needs without duplicating the boilerplate fields.
#
# gateway and dns both point at the router VM's private IP - workload
# traffic egresses through the router (which MASQUERADEs out its
# upstream NIC) and DNS queries go to dnsmasq running on the same
# router. subnetMask is fixed to the per-test private subnet's /24,
# not operator-supplied: the private network is fully internal to the
# test fixture.
function New-VmEntryBase {
    [CmdletBinding()]
    # $Password is forwarded verbatim into the provisioner REST payload's
    # plaintext 'password' field; a SecureString cannot round-trip into a
    # JSON body, so the conversion would add ceremony without cutting
    # exposure. Suppressed at the parameter, the rule stays live elsewhere.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'Forwarded as plaintext into the provisioner REST payload')]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Config,
        [Parameter(Mandatory)] [string] $VmName,
        [Parameter(Mandatory)] [string] $IpAddress,
        [Parameter(Mandatory)] [string] $Password
    )

    return [ordered]@{
        vmName            = $VmName
        cpuCount          = 2
        ramGB             = 2
        diskGB            = 20
        ubuntuVersion     = $Config.TestVm.ubuntuVersion
        username          = 'e2eadmin'
        password          = $Password
        ipAddress         = $IpAddress
        subnetMask        = $script:PrivateSubnetMask
        gateway           = $script:RouterPrivateIp
        dns               = $script:RouterPrivateIp
        vmConfigPath      = $Config.TestVm.vmConfigPath
        vhdPath           = $Config.TestVm.vhdPath
        privateSwitchName = $script:PrivateSwitchName
    }
}

# Projects $script:ToolchainAptPackages into the JSON shape a VM config entry's
# `toolchains` block takes (lowercase keys, {name, version} per apt package, plus
# the section-3 presence gate). Kept as a projection rather than a second literal
# so adding a package to that list is the only edit needed - the declaration the
# assertions read and the config the flow installs from cannot diverge.
#
# vmDownloaded is a per-mechanism object ({ apt, batsLibs }), not a flat list:
# section 2 spans two installers (apt packages and GitHub-tarball bats
# libraries). Both are projected from their declaration lists so the config the
# flow installs from and the declarations the assertions read cannot diverge.
function New-ToolchainsTaxonomyBlock {
    [CmdletBinding()]
    param()

    return [ordered]@{
        vmDownloaded = [ordered]@{
            apt = @($script:ToolchainAptPackages | ForEach-Object {
                [ordered]@{ name = $_.Name; version = $_.Version }
            })
            batsLibs = @($script:ToolchainBatsLibs | ForEach-Object {
                [ordered]@{ name = $_.Name; version = $_.Version }
            })
        }
        baseImage    = @(
            [ordered]@{ name = $script:ToolchainBaseImageDocker }
        )
    }
}

# Builds the router-VM entry consumed by provision.ps1's router-seed
# path (feature 53 step 1). Two NICs: ext0 on the host's External
# vSwitch (upstream egress; STATIC IP from $Config.TestVm.routerExternalIp
# / routerExternalGateway so the run does not depend on a reachable DHCP
# server: ICS DHCP silently breaks across Wi-Fi network changes, and
# bridged-Wi-Fi DHCP collides via shared MAC at the AP). priv0 on the
# per-test Private
# vSwitch (downstream gateway and DNS for workloads, always static).
function New-RouterEntry {
    [CmdletBinding()]
    # See New-VmEntryBase: $Password reaches the provisioner only as a
    # plaintext REST field, so SecureString would add ceremony without
    # cutting exposure. Suppressed at the parameter; the rule stays live.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'Forwarded as plaintext into the provisioner REST payload')]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Config,
        [Parameter(Mandatory)] [string] $Password
    )

    # subnetMask is the universal /24 for both NICs in this test
    # topology - priv0 always 10.99.0.0/24 (RouterPrivateIp + .10/.11
    # workloads), ext0 always the Config-supplied router-upstream
    # subnet (/24 per ICS default 192.168.137.0 / per-operator-LAN).
    return [ordered]@{
        vmName              = $script:RouterVmName
        cpuCount            = 1
        ramGB               = 1
        diskGB              = 20
        ubuntuVersion       = $Config.TestVm.ubuntuVersion
        username            = $script:RouterUsername
        password            = $Password
        subnetMask          = $script:PrivateSubnetMask
        dns                 = $Config.TestVm.dns
        vmConfigPath        = $Config.TestVm.vmConfigPath
        vhdPath             = $Config.TestVm.vhdPath
        kind                = 'router'
        externalSwitchName  = $Config.TestVm.externalSwitchName
        externalAdapterName = $Config.TestVm.externalAdapterName
        # Static ext0. externalDhcp=false forces the static path in
        # Assert-RouterVmField, which then requires ipAddress + gateway.
        externalDhcp        = $false
        ipAddress           = $Config.TestVm.routerExternalIp
        gateway             = $Config.TestVm.routerExternalGateway
        privateSwitchName   = $script:PrivateSwitchName
        privateIpAddress    = $script:RouterPrivateIp
    }
}

# VmProvisionerConfig must be a JSON array - ConvertFrom-VmConfigJson
# rejects a bare object. Centralised so the JSON depth, the Set-Secret
# parameters, and the array-wrapping live in one place across all phases.
#
# The router VM is always prepended to the workload entries. Phases
# only describe the workload state they care about; the router stays
# byte-identical across rewrites (Setup mints it once) so the
# provisioner reconciler sees it as unchanged and takes the no-op
# branch on phases 2 and 3. Provisioning the router first is implicit
# in the JSON order - provision.ps1 walks the array; the router is
# always position 0.
function Write-VmProvisionerConfig {
    [CmdletBinding()]
    param(
        # Workload entries (ordered dictionaries / PSCustomObjects). The
        # router VM is added by this function from $script:RouterEntry;
        # callers MUST NOT include it themselves.
        [Parameter(Mandatory)]
        [object[]] $Entries
    )

    if ($null -eq $script:RouterEntry) {
        throw "Write-VmProvisionerConfig: \$script:RouterEntry is not set. " +
            "Invoke-VmProvisioningSetup must run before any phase."
    }

    $entriesWithRouter = @($script:RouterEntry) + @($Entries)

    Set-Secret `
        -Vault  VmProvisioner `
        -Name   (Get-E2ESecretName 'VmProvisionerConfig') `
        -Secret (ConvertTo-Json $entriesWithRouter -Depth 5 -Compress)
}

# Builds the router + VM1 + VM2 vmDefs once, up front. Passwords are
# generated here so each phase's rewrite of VmProvisionerConfig reuses
# the same credentials - changing them mid-scenario would invalidate
# prior phases' SSH sessions. Workload IPs are constants (10.99.0.10
# and .11) on the per-test private subnet; only the router's upstream
# IP is operator-supplied via $Config.TestVm.routerExternalIp.
function New-PinnedVmDefinitions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Config
    )

    # Router VM def carries the upstream-NIC IP (used as the SSH host),
    # the username minted at Setup, and the router-only fields the
    # white-box assertion files read (privateIpAddress for the
    # downstream-NIC check).
    #
    # Retain the original [ordered]@{} that New-RouterEntry returns
    # AND its PSCustomObject view so a single source-of-truth flows
    # to both consumers without hand-copying field lists:
    #   - $routerDef        : PSCustomObject for white-box assertions
    #                          and Add-Member sites (test path uses
    #                          dot-access; provision.ps1 stamps
    #                          ipAddress on the workload VM defs via
    #                          their _RouterVm reference).
    #   - $routerEntry      : [ordered] hashtable used verbatim as
    #                          $script:RouterEntry by
    #                          Write-VmProvisionerConfig - same shape
    #                          serialised to JSON for the vault.
    # The PSCustomObject and the hashtable are independent objects
    # (`[PSCustomObject] $h` copies the entries into a new PSObject),
    # so any Add-Member to $routerDef does not bleed into $routerEntry.
    $routerEntry = New-RouterEntry `
        -Config   $Config `
        -Password (New-VmProvisioningPassword)
    $routerDef   = [PSCustomObject] $routerEntry

    $vm1Def = [PSCustomObject](New-VmEntryBase `
        -Config    $Config `
        -VmName    $script:Vm1Name `
        -IpAddress $script:Vm1Ip `
        -Password  (New-VmProvisioningPassword))

    $vm2Def = [PSCustomObject](New-VmEntryBase `
        -Config    $Config `
        -VmName    $script:Vm2Name `
        -IpAddress $script:Vm2Ip `
        -Password  (New-VmProvisioningPassword))

    return [PSCustomObject]@{
        RouterVm    = $routerDef
        RouterEntry = $routerEntry
        Vm1         = $vm1Def
        Vm2         = $vm2Def
    }
}

# Opens an SSH client to a VM, runs the supplied script block with the
# client as its sole argument, and disposes the client regardless of
# outcome. Centralises the connect / try / finally / dispose pattern so
# each phase does not redo it inline.
function Invoke-WithVmSshClient {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $VmDef,
        [Parameter(Mandatory)] [scriptblock] $Assertions
    )

    # Workload VMs sit on the per-environment private switch the host
    # has no route to (feature 53). Their VM def carries _RouterVm
    # (stamped by provision.ps1 step 7) - delegate session construction
    # to Infrastructure.HyperV's New-VmSshClientWithJump so the test
    # path and the provisioner's post-provisioning path share the same
    # jump-vs-direct decision and credential surface. Routers and
    # pre-feature-53 callers get a direct New-VmSshClient via the
    # same helper.
    $sshSession = $null
    try {
        $sshSession = New-VmSshClientWithJump -Vm $VmDef
        & $Assertions $sshSession.Client
    }
    finally {
        if ($null -ne $sshSession) {
            try { $sshSession.Dispose() } catch { Write-Verbose "Ignoring SSH session dispose failure: $($_.Exception.Message)" }
        }
    }
}

# Seeds an out-of-block sentinel line on the VM and snapshots the
# resulting /etc/environment mtime. Used by phase 1 (after the first
# managed-block write) so phases 2 and 3 can assert (a) the line
# survives subsequent re-runs and (b) phase 2's re-write actually
# updates the file. Uses tee -a under sudo so the append is atomic
# from the operator's perspective; the line lands after the END
# marker, so it is unambiguously outside the managed block.
function Set-VmEnvironmentMarkerAndSnapshotMtime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName
    )

    # Idempotence: append only when the line is not already there, so
    # a re-run of phase 1 (e.g. during local debugging) does not
    # accumulate duplicate marker lines.
    $append = "grep -Fxq '$($script:EnvVarsMarkerLine)' /etc/environment || " +
        "echo '$($script:EnvVarsMarkerLine)' | sudo tee -a /etc/environment >/dev/null"
    $result = Invoke-SshClientCommand -SshClient $SshClient -Command $append
    if ($result.ExitStatus -ne 0) {
        throw "Failed to seed MARKER_OUTSIDE on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }

    # mtime as Unix epoch seconds - phase 2 compares numerically, so we
    # avoid timezone surprises that string timestamps would introduce.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "stat -c '%Y' /etc/environment"
    if ($result.ExitStatus -ne 0) {
        throw "stat -c %Y on /etc/environment failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $script:EnvVarsPhase1Mtime = [int64]$result.Output.Trim()
    Write-Host "  [seed] MARKER_OUTSIDE in place; /etc/environment mtime=$($script:EnvVarsPhase1Mtime)" `
        -ForegroundColor Magenta
}

# E6 helper: asserts /etc/environment's mtime advanced past the phase-1
# snapshot. The transport's skip-unchanged path would leave the mtime
# stale; phase 2 changes the block content (BAR_VAR removed) so a
# stale mtime indicates either the transport never ran or the file
# was not actually rewritten.
function Assert-EtcEnvironmentMtimeAdvanced {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName
    )

    if ($null -eq $script:EnvVarsPhase1Mtime) {
        throw "Assert-EtcEnvironmentMtimeAdvanced: phase 1 did not snapshot " +
            "an mtime - phases ran out of order."
    }
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "stat -c '%Y' /etc/environment"
    if ($result.ExitStatus -ne 0) {
        throw "stat -c %Y on /etc/environment failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $now = [int64]$result.Output.Trim()
    if ($now -le $script:EnvVarsPhase1Mtime) {
        throw "/etc/environment mtime did not advance on $VmName " +
            "(phase 1 snapshot $($script:EnvVarsPhase1Mtime), now $now). " +
            "Transport likely skipped the write - block contents may be stale."
    }
    Write-Host "  [OK] /etc/environment mtime advanced ($($script:EnvVarsPhase1Mtime) -> $now)" `
        -ForegroundColor Green
}

# StrictMode-safe read of the session's ToolchainsFlow off $Config. Both
# the agent (from the deployment payload) and the standalone
# Start-VmProvisioningTest thread it into the Config; the fallback below
# fires only for a Config that omits the property and mirrors the
# agent-loop default, so an absent value lands on the same engine.
function Resolve-ToolchainsFlow {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $Config)

    if ($Config.PSObject.Properties['ToolchainsFlow'] -and $Config.ToolchainsFlow) {
        return $Config.ToolchainsFlow
    }
    return 'ansible'
}

# Resolves the engine-specific parameters the jdk / dotnet assertion
# helpers take (step 5.5-A.5) for the session's ToolchainsFlow. Returned as
# splat-ready hashtables so each phase can pass them into the assertions
# without branching at every call site:
#   .Jdk / .Sdk        - install prefix (+ manifest store & prefix under
#                        ansible) shared by that toolchain's install /
#                        uninstall / version-change / noop assertions.
#   .Tools             - manifest store & prefix for the dotnet_tools
#                        assertions (they carry no install prefix).
#   .ToolInstallExtra  - extra args for the tool INSTALL assertion only:
#                        under ansible, -SkipReconcilerManifestSchema, since
#                        that engine's manifest content schema and its lack
#                        of a parent-SDK 'children' walker link are the
#                        role's own molecule concern, not an E2E end-state.
# For custom-powershell every hashtable carries only the reconciler install
# prefix (or nothing), so the assertions fall back to their reconciler
# defaults and the existing run is unchanged.
function Get-ToolchainAssertionParamSets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('custom-powershell', 'ansible')]
        [string] $ToolchainsFlow
    )

    if ($ToolchainsFlow -eq 'ansible') {
        return [PSCustomObject]@{
            Jdk = @{
                InstallPrefix      = $script:AnsibleJdkInstallPrefix
                ManifestStoreDir   = $script:AnsibleManifestStoreDir
                ManifestFilePrefix = $script:AnsibleJdkManifestPrefix
            }
            Sdk = @{
                InstallPrefix      = $script:DotnetInstallPrefix
                ManifestStoreDir   = $script:AnsibleManifestStoreDir
                ManifestFilePrefix = $script:AnsibleSdkManifestPrefix
            }
            Tools = @{
                ManifestStoreDir   = $script:AnsibleManifestStoreDir
                ManifestFilePrefix = $script:AnsibleToolManifestPrefix
            }
            ToolInstallExtra = @{ SkipReconcilerManifestSchema = $true }
        }
    }

    # custom-powershell: pass the reconciler install prefixes explicitly (as
    # the phases always have); manifest store / prefixes default to the
    # reconciler layout inside the assertions, so nothing else is passed.
    return [PSCustomObject]@{
        Jdk              = @{ InstallPrefix = $script:JdkInstallPrefix }
        Sdk              = @{ InstallPrefix = $script:DotnetInstallPrefix }
        Tools            = @{}
        ToolInstallExtra = @{}
    }
}

# One-call context bundle each phase resolves at its top: the flow string,
# the boolean the branch points read, the assertion param sets, and the
# (StrictMode-safe) WSL distro the ansible driver needs. Keeps the
# per-phase toolchain-flow boilerplate to a single line.
function Get-ToolchainPhaseContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $Config)

    $flow = Resolve-ToolchainsFlow -Config $Config
    return [PSCustomObject]@{
        Flow      = $flow
        IsAnsible = $flow -eq 'ansible'
        Params    = Get-ToolchainAssertionParamSets -ToolchainsFlow $flow
        WslDistro = if ($Config.PSObject.Properties['WslDistro']) {
            $Config.WslDistro
        } else { $null }
    }
}

# StrictMode-safe read of the session's FilesFlow off $Config. Peer of
# Resolve-ToolchainsFlow, including the fallback: a Config that omits the
# property lands on the same engine the agent loop defaults to.
function Resolve-FilesFlow {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $Config)

    if ($Config.PSObject.Properties['FilesFlow'] -and $Config.FilesFlow) {
        return $Config.FilesFlow
    }
    return 'ansible'
}

# One-call context bundle each phase resolves at its top, mirroring
# Get-ToolchainPhaseContext. Shorter by one field: the file-transfer assertions
# are engine-agnostic (same target path, root:root, 0644 under either engine),
# so there is no per-engine assertion param set to resolve - only the flow, the
# boolean the branch points read, and the WSL distro the ansible driver needs.
function Get-FilesPhaseContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [PSCustomObject] $Config)

    $flow = Resolve-FilesFlow -Config $Config
    return [PSCustomObject]@{
        Flow      = $flow
        IsAnsible = $flow -eq 'ansible'
        WslDistro = if ($Config.PSObject.Properties['WslDistro']) {
            $Config.WslDistro
        } else { $null }
    }
}

# Runs the provisioner for a phase. Each ansible engine axis stands the
# matching in-line provision.ps1 step down so the separate Ansible driver owns
# it instead: -SkipToolchains leaves the toolchains to provision-toolchains.sh
# (Set-VmToolchainsForTest), -SkipFiles leaves the `files` transport to
# provision-files.sh (Set-VmFilesForTest). Under custom-powershell
# provision.ps1 does that half in-line. The per-VM desired state lives in
# VmProvisionerConfig either way - only these two arguments differ by engine, so
# centralising them keeps every phase's provisioning call identical.
function Invoke-ProvisionerForPhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Config,
        [Parameter(Mandatory)] [PSCustomObject] $Tcx,
        [Parameter(Mandatory)] [PSCustomObject] $Fcx
    )

    # Hashtable splat, NOT an array. Array splatting passes every element
    # as a POSITIONAL argument - '-SecretSuffix' would bind to provision.ps1's
    # lone positional slot and 'E2E' would spill over as an unbindable second
    # positional ("A positional parameter cannot be found that accepts
    # argument 'E2E'"). A hashtable maps each key to the matching -Named
    # parameter, and a $true value drives the [switch].
    $provArgs = @{ SecretSuffix = $script:E2ETestSecretSuffix }
    if ($Tcx.IsAnsible) { $provArgs['SkipToolchains'] = $true }
    if ($Fcx.IsAnsible) { $provArgs['SkipFiles']      = $true }
    & "$($Config.ProvisionerPath)\hyper-v\ubuntu\PowerShell\provision.ps1" @provArgs
}

# Phase functions. One file per phase so each is independently reviewable
# and unit-testable. They reach back into the orchestrator helpers above
# (New-VmEntryBase, Write-VmProvisionerConfig, Invoke-WithVmSshClient) and
# the $script:* constants, so the dot-sources MUST come after the helper
# and constant definitions in this file.
. "$PSScriptRoot\phases\Invoke-VmProvisioningPhase1.ps1"
. "$PSScriptRoot\phases\Invoke-VmProvisioningPhase2.ps1"
. "$PSScriptRoot\phases\Invoke-VmProvisioningPhase3.ps1"

# Teardown assertions must be defined before Teardown, because
# Invoke-VmProvisioningTeardown calls Invoke-VmTeardownAssertions at the
# end of its run.
. "$PSScriptRoot\assertions\lifecycle\Invoke-VmTeardownAssertions.ps1"
. "$PSScriptRoot\phases\Invoke-VmProvisioningTeardown.ps1"

# ---------------------------------------------------------------------------
# Invoke-VmProvisioningSetup
#   Pre-flight only: imports Hyper-V, asserts both test VMs are absent,
#   and pins both VM identities (vmName, ipAddress, credentials).
#   Returns the VM1 vmDef with VM2's vmDef attached as the '_SecondaryVm'
#   NoteProperty so downstream callers can drive each phase with the
#   same pinned identity. Underscore prefix marks it as an internal
#   handoff field - external consumers should treat it as opaque.
#
#   NO provisioning happens here. Each phase (1, 2, 3) is one VmProvisioner
#   config write + one provision.ps1 invocation + its assertions; Phase 1
#   is the operator's first provision of the scenario, and callers invoke
#   it explicitly right after Setup. Keeping Setup provisioning-free
#   matches the symmetry across phases and means a caller that doesn't
#   yet want a VM up (e.g. a future test that only exercises validation)
#   can still use Setup.
#
#   Teardown counterpart: Invoke-VmProvisioningTeardown (which calls
#   Invoke-VmTeardownAssertions at the end of its own run).
# ---------------------------------------------------------------------------

function Invoke-VmProvisioningSetup {
    [CmdletBinding()]
    param(
        # Config object from Start-E2EAgent.ps1.
        # Must include ProvisionerPath and TestVm (see E2EConfig vault shape).
        [Parameter(Mandatory)]
        [PSCustomObject] $Config
    )

    # Hyper-V module is not auto-imported in the agent session - provision.ps1
    # loads it only inside its own child process. Import it explicitly so
    # Get-VM below is available.
    Import-Module Hyper-V -ErrorAction Stop

    Invoke-NoLeftoverTestVmsAssertions

    $vmDefs = New-PinnedVmDefinitions -Config $Config

    # Stash the router entry so Write-VmProvisionerConfig can prepend it
    # to every phase's array. The router's NoteProperties carry the SSH
    # credentials and the load-bearing router-specific fields
    # (privateIpAddress) the white-box assertions read.
    #
    # Single source of truth: $vmDefs.RouterEntry IS the [ordered]
    # hashtable New-RouterEntry produced. Previously this site
    # hand-copied each field, which silently dropped any field
    # New-RouterEntry added later (see the externalDhcp/ipAddress/
    # gateway addition where the inline copy missed those fields and
    # the vault ended up with externalDhcp absent, falling back to
    # the schema's DHCP default). One source means future additions
    # to New-RouterEntry flow through automatically.
    $script:RouterEntry = $vmDefs.RouterEntry

    # Stash the router def alongside the SecondaryVm so callers reach
    # it the same way they reach Vm2 - $vmDef._RouterVm. Stamp both
    # Vm1 AND Vm2 with _RouterVm so phase assertions that target
    # either VM (via Invoke-WithVmSshClient -> New-VmSshClientWithJump)
    # automatically take the jump-through-router branch. The router
    # VM def is shared by both workloads: when create-vm.ps1's KVP
    # discovery (or provision.ps1's existing-router resolution)
    # writes ipAddress onto the router object, both VMs' _RouterVm
    # references see the populated value.
    Add-Member -InputObject $vmDefs.Vm1 `
        -MemberType NoteProperty -Name '_SecondaryVm' -Value $vmDefs.Vm2 -Force
    Add-Member -InputObject $vmDefs.Vm1 `
        -MemberType NoteProperty -Name '_RouterVm' -Value $vmDefs.RouterVm -Force
    Add-Member -InputObject $vmDefs.Vm2 `
        -MemberType NoteProperty -Name '_RouterVm' -Value $vmDefs.RouterVm -Force

    return $vmDefs.Vm1
}

# ---------------------------------------------------------------------------
# Invoke-VmProvisioningTest
#   Standalone four-phase provisioning E2E for the manual runner
#   (Start-VmProvisioningTest.ps1). Drives the phases directly because
#   the provisioning-only test has no users / runner layers to inject
#   between phases.
#
#   The lifecycle path (Start-E2EAgent -> Invoke-RunnerLifecycleTest ->
#   Invoke-VmUsersTest) calls Invoke-VmProvisioningSetup itself, runs
#   its users / runner setup on the freshly provisioned VM1, then drives
#   phases 2-3 with the same helpers used here - re-asserting users +
#   runner intact between phases.
# ---------------------------------------------------------------------------

function Invoke-VmProvisioningTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Config
    )

    # Wrapped in try/finally so Teardown (with its embedded
    # Invoke-VmTeardownAssertions call) still runs if any phase throws
    # after a VM was created. deprovision.ps1 is idempotent so a partial
    # teardown is safe.
    $vm1Def = $null
    try {
        $vm1Def = Invoke-VmProvisioningSetup -Config $Config
        $vm2Def = $vm1Def._SecondaryVm

        Invoke-VmProvisioningPhase1 -Config $Config -Vm1Def $vm1Def
        Invoke-VmProvisioningPhase2 -Config $Config -Vm1Def $vm1Def -Vm2Def $vm2Def
        Invoke-VmProvisioningPhase3 -Config $Config -Vm1Def $vm1Def -Vm2Def $vm2Def
    }
    finally {
        Invoke-VmProvisioningTeardown -Config $Config
    }
}
