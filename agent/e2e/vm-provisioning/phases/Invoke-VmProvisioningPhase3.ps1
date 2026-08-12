<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Common.PowerShell, the assertion helpers, and the shared
    orchestrator helpers are loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-VmProvisioningPhase3
#   Phase 3 - version change on VM1 (JDK reinstall -> initial), then
#   remove-via-empty on VM1.
#
#   Sub-phase 3a (first provision):
#     - VM1's javaDevKit.version flips from $JdkReinstallVersion (installed
#       by phase 2b) to $JdkInitialVersion. The reconciler must uninstall
#       the old install dir + manifest and install the new one in the
#       same provision run.
#
#   Sub-phase 3b (second provision):
#     - VM1's javaDevKit becomes an explicit empty list (the "ensure
#       none via @()" contract) and envVars.entries becomes empty as
#       well (the existing managed-block removal scenario, retained
#       from the pre-reconciler phase 3).
#
#   VM2 is unchanged across both sub-phases and is re-checked at the end
#   to confirm two more JDK steps on VM1 (one change, one remove) did
#   not leak across.
# ---------------------------------------------------------------------------

function Invoke-VmProvisioningPhase3 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Config,
        [Parameter(Mandatory)] [PSCustomObject] $Vm1Def,
        [Parameter(Mandatory)] [PSCustomObject] $Vm2Def,

        # Timing context threaded from the runner-lifecycle 'Phase 3 +
        # reassert' span. When supplied, each sub-phase shell-out below
        # (provision + toolchains) records as a nested child span with its
        # OWN per-invocation output path, so provision.ps1's and
        # provision-toolchains.sh's exported trees graft in separately rather
        # than clobbering each other on one shared path (feature 88 E2). The
        # standalone vm-provisioning flow passes none; a throwaway tree then
        # absorbs the spans so the wrapping stays uniform.
        [object] $Tree = $null
    )

    if ($null -eq $Tree) {
        $Tree = New-TimingSpanTree -RootName 'vm-provisioning-phase3'
    }

    $tcx = Get-ToolchainPhaseContext -Config $Config
    # Independent file-transport engine axis - see the note in phase 1. VM1
    # declares no `files` from 3a onward, so the ansible driver runs against an
    # empty per-host entry list; vm_files is a no-op on one, which makes these
    # passes the "declared nothing, transported nothing" check.
    $fcx = Get-FilesPhaseContext -Config $Config
    # Environment-block engine for this run, a third independent axis. Peer of
    # $fcx; see phase 1 for why the managed block is the one artefact both
    # engines can own in turn.
    $ecx = Get-EnvVarsPhaseContext -Config $Config
    $jdkParams        = $tcx.Params.Jdk
    $sdkParams        = $tcx.Params.Sdk
    $toolParams       = $tcx.Params.Tools
    $toolInstallExtra = $tcx.Params.ToolInstallExtra

    # 3a version-changes VM1 to JDK 21 + dotnet SDK 8.0.100 + the tool at its
    # reinstall pin. 3b removes every toolchain (@() empty lists - the "ensure
    # none" signal both engines honour). The desired state is authored directly
    # in the per-VM VmProvisionerConfig blocks below for both engines.

    Write-Host '' -ForegroundColor Magenta
    Write-Host ("Phase 3a: rewriting VmProvisionerConfig - VM1 changes JDK " +
                "$($script:JdkReinstallVersion) -> $($script:JdkInitialVersion) and " +
                "dotnet SDK $($script:DotnetReinstallResolvedVersion) -> $($script:DotnetInitialResolvedVersion) ...") `
        -ForegroundColor Magenta

    # 3a) VM1 entry: bump javaDevKit.version + dotnetSdk version. Both
    # are changed in the same provision run so the reconciler must
    # observably uninstall+install for each provider without the two
    # interfering. Everything else is unchanged.
    $vm1Entry = New-VmEntryBase `
        -Config    $Config `
        -VmName    $Vm1Def.vmName `
        -IpAddress $Vm1Def.ipAddress `
        -Password  $Vm1Def.password
    # Version-change the toolchain blocks in place - same blocks for both
    # engines (ansible drives the swap via provision-toolchains.sh under
    # provision.ps1 -SkipToolchains).
    $vm1Entry.javaDevKit = [ordered]@{
        vendor  = $script:JdkTestVendor
        version = $script:JdkInitialVersion
    }
    $vm1Entry.dotnetSdk = [ordered]@{
        channel = $script:DotnetInitialChannel
        version = $script:DotnetInitialResolvedVersion
    }
    # dotnetTools version flips from $DotnetToolInitialVersion (installed
    # by phase 2b) to $DotnetToolReinstallVersion at the same time as the
    # SDK version-change. Running both swaps in one provision run
    # exercises the walker on the SDK uninstall side (which must
    # dispatch the existing tool's Uninstall-Version before tearing
    # down the SDK so the SDK install dir is empty by the time it is
    # removed). After the SDK reinstall the tool provider then installs
    # the new tool version under the new SDK.
    $vm1Entry.dotnetTools = @(
        [ordered]@{
            id      = $script:DotnetToolId
            version = $script:DotnetToolReinstallVersion
        }
    )
    # envVars unchanged from phase 2b - still narrowed to FOO_HOME so
    # no spurious managed-block diff masks the JDK change.
    $vm1Entry.envVars = [ordered]@{
        blockName = $script:EnvVarsBlockName
        entries   = @(
            [ordered]@{ name = $script:EnvVarsFooHome.Name; value = $script:EnvVarsFooHome.Value }
        )
    }

    $vm2Entry = New-VmEntryBase `
        -Config    $Config `
        -VmName    $Vm2Def.vmName `
        -IpAddress $Vm2Def.ipAddress `
        -Password  $Vm2Def.password

    Write-VmProvisionerConfig -Entries @($vm1Entry, $vm2Entry)

    Write-Host 'Phase 3a: provisioning (version change on VM1) ...' `
        -ForegroundColor Magenta
    Measure-ChildProcessTimingSpan -Tree $Tree -Name '3a provision' -Action {
        Invoke-ProvisionerForPhase -Config $Config -Tcx $tcx -Fcx $fcx -Ecx $ecx
    }

    # Ansible flow: runs against VM1's now-empty `files` declaration - the
    # driver must complete cleanly rather than fail on a host with nothing to
    # transport (no-op under custom-powershell). Precedes the toolchains driver,
    # as at every site.
    Measure-ChildProcessTimingSpan -Tree $Tree -Name '3a files' -Action {
        Set-VmFilesForTest `
            -FilesFlow       $fcx.Flow `
            -ProvisionerPath $Config.ProvisionerPath `
            -WslDistro       $fcx.WslDistro
    }

    # Ansible flow: drive the version-change by reconciling VM1's per-VM
    # toolchain state from VmProvisionerConfig (no-op under custom-powershell,
    # which swapped inside provision.ps1).
    Measure-ChildProcessTimingSpan -Tree $Tree -Name '3a toolchains' -Action {
        Set-VmToolchainsForTest `
            -ToolchainsFlow  $tcx.Flow `
            -ProvisionerPath $Config.ProvisionerPath `
            -WslDistro       $tcx.WslDistro
    }

    Measure-ChildProcessTimingSpan -Tree $Tree -Name '3a env' -Action {
        Set-VmEnvVarsForTest `
            -EnvVarsFlow     $ecx.Flow `
            -ProvisionerPath $Config.ProvisionerPath `
            -WslDistro       $ecx.WslDistro
    }

    Write-Host "Phase 3a: verifying version change on $($Vm1Def.vmName) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm1Def -Assertions {
        param($sshClient)
        Invoke-VmReadyAssertions -SshClient $sshClient -VmName $Vm1Def.vmName
        Invoke-StaticNetworkAssertions -SshClient $sshClient -VmDef $Vm1Def
        Invoke-EgressAssertions -SshClient $sshClient -VmName $Vm1Def.vmName

        # Old-side cleanup + symlink re-target.
        Invoke-JdkVersionChangeAssertions `
            -SshClient                $sshClient `
            -VmName                   $Vm1Def.vmName `
            -PreviousRequestedVersion $script:JdkReinstallVersion `
            -NewRequestedVersion      $script:JdkInitialVersion `
            @jdkParams

        # New-side install (JAVA_HOME, PATH, java -version, manifest
        # present). Together with VersionChange's V1-V4 this covers the
        # full swap contract.
        Invoke-JdkInstallAssertions `
            -SshClient        $sshClient `
            -VmName           $Vm1Def.vmName `
            -RequestedVersion $script:JdkInitialVersion `
            @jdkParams

        # Same swap pair for the dotnet SDK.
        Invoke-DotnetSdkVersionChangeAssertions `
            -SshClient                $sshClient `
            -VmName                   $Vm1Def.vmName `
            -PreviousResolvedVersion  $script:DotnetReinstallResolvedVersion `
            -NewResolvedVersion       $script:DotnetInitialResolvedVersion `
            @sdkParams

        Invoke-DotnetSdkInstallAssertions `
            -SshClient       $sshClient `
            -VmName          $Vm1Def.vmName `
            -ResolvedVersion $script:DotnetInitialResolvedVersion `
            @sdkParams

        # Old store gone + new store present + manifest swap + symlink
        # survives. The plain "install assertion against the new tool
        # version" pass below covers --version output, manifest contents,
        # and (reconciler flow) the parent SDK's children array referencing
        # the new tool manifest.
        Invoke-DotnetToolsVersionChangeAssertions `
            -SshClient        $sshClient `
            -VmName           $Vm1Def.vmName `
            -ToolId           $script:DotnetToolId `
            -PreviousVersion  $script:DotnetToolInitialVersion `
            -NewVersion       $script:DotnetToolReinstallVersion `
            -Command          $script:DotnetToolCommand `
            @toolParams

        Invoke-DotnetToolsInstallAssertions `
            -SshClient   $sshClient `
            -VmName      $Vm1Def.vmName `
            -ToolId      $script:DotnetToolId `
            -ToolVersion $script:DotnetToolReinstallVersion `
            -Command     $script:DotnetToolCommand `
            @toolParams @toolInstallExtra
    }

    # ------------------------------------------------------------------
    # 3b) Remove via empty list. javaDevKit = @() is the explicit
    # "ensure none" contract (companion to "drop the field" exercised
    # in 2a); envVars.entries = @() drives the managed-block removal.
    # ------------------------------------------------------------------
    Write-Host '' -ForegroundColor Magenta
    Write-Host 'Phase 3b: rewriting VmProvisionerConfig - VM1 javaDevKit = @() + dotnetSdk = @() + envVars empty ...' `
        -ForegroundColor Magenta

    $vm1Entry = New-VmEntryBase `
        -Config    $Config `
        -VmName    $Vm1Def.vmName `
        -IpAddress $Vm1Def.ipAddress `
        -Password  $Vm1Def.password
    # Explicit empty lists are the "ensure none" signal (distinct from 2a's
    # explicit $null so both ensure-none contracts are exercised). dotnetTools =
    # @() combined with dotnetSdk = @() exercises the composite tear-down: the
    # tool provider goes first per Get-Providers order, leaving the SDK's
    # children array empty by the time the SDK uninstall fires - the path plan
    # step 7 step 4's regression guard cares about (orphan manifest leftover
    # would fail U3). Same empty blocks for both engines; ansible drives the
    # uninstall via provision-toolchains.sh under provision.ps1 -SkipToolchains.
    $vm1Entry.javaDevKit  = @()
    $vm1Entry.dotnetSdk   = @()
    $vm1Entry.dotnetTools = @()
    $vm1Entry.envVars = [ordered]@{
        blockName = $script:EnvVarsBlockName
        entries   = @()
    }

    $vm2Entry = New-VmEntryBase `
        -Config    $Config `
        -VmName    $Vm2Def.vmName `
        -IpAddress $Vm2Def.ipAddress `
        -Password  $Vm2Def.password

    Write-VmProvisionerConfig -Entries @($vm1Entry, $vm2Entry)

    Write-Host 'Phase 3b: provisioning (uninstall via empty list on VM1) ...' `
        -ForegroundColor Magenta
    Measure-ChildProcessTimingSpan -Tree $Tree -Name '3b provision' -Action {
        Invoke-ProvisionerForPhase -Config $Config -Tcx $tcx -Fcx $fcx -Ecx $ecx
    }

    # Ansible flow: same empty-declaration pass as 3a (no-op under
    # custom-powershell).
    Measure-ChildProcessTimingSpan -Tree $Tree -Name '3b files' -Action {
        Set-VmFilesForTest `
            -FilesFlow       $fcx.Flow `
            -ProvisionerPath $Config.ProvisionerPath `
            -WslDistro       $fcx.WslDistro
    }

    # Ansible flow: drive the uninstall by reconciling VM1's (now empty) per-VM
    # toolchain state from VmProvisionerConfig (no-op under custom-powershell,
    # which uninstalled inside provision.ps1).
    Measure-ChildProcessTimingSpan -Tree $Tree -Name '3b toolchains' -Action {
        Set-VmToolchainsForTest `
            -ToolchainsFlow  $tcx.Flow `
            -ProvisionerPath $Config.ProvisionerPath `
            -WslDistro       $tcx.WslDistro
    }

    Measure-ChildProcessTimingSpan -Tree $Tree -Name '3b env' -Action {
        Set-VmEnvVarsForTest `
            -EnvVarsFlow     $ecx.Flow `
            -ProvisionerPath $Config.ProvisionerPath `
            -WslDistro       $ecx.WslDistro
    }

    Write-Host "Phase 3b: verifying remove-via-empty on $($Vm1Def.vmName) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm1Def -Assertions {
        param($sshClient)
        Invoke-VmReadyAssertions -SshClient $sshClient -VmName $Vm1Def.vmName
        Invoke-EgressAssertions -SshClient $sshClient -VmName $Vm1Def.vmName
        Invoke-JdkUninstallAssertions `
            -SshClient     $sshClient `
            -VmName        $Vm1Def.vmName `
            @jdkParams

        Invoke-DotnetSdkUninstallAssertions `
            -SshClient     $sshClient `
            -VmName        $Vm1Def.vmName `
            @sdkParams

        Invoke-DotnetToolsUninstallAssertions `
            -SshClient $sshClient `
            -VmName    $Vm1Def.vmName `
            -ToolId    $script:DotnetToolId `
            -Command   $script:DotnetToolCommand `
            @toolParams

        # envVars: E7 (markers gone), E8 (formerly-managed entries
        # gone), E1 (mode unchanged), E3 (MARKER_OUTSIDE still
        # present). Names listed explicitly (not derived from the
        # phase-1 fixtures) so a future fixture rename does not
        # silently weaken the assertion.
        Invoke-EnvVarsRemovedAssertions `
            -SshClient          $sshClient `
            -VmName             $Vm1Def.vmName `
            -RemovedBlockName   $script:EnvVarsBlockName `
            -RemovedEntryNames  @($script:EnvVarsFooHome.Name, $script:EnvVarsBarVar.Name) `
            -ExpectedMarkerLine $script:EnvVarsMarkerLine
    }

    # VM2 "no leak" witness (see the phase 2 notes): VM2 carries no toolchain
    # fields, so under BOTH engines it stays clean across every VM1 toolchain
    # step - the per-host Ansible flow omits it from its resolved map exactly as
    # the reconciler skips it.
    Write-Host ("Phase 3b: re-verifying VM2 has no JDK / dotnet " +
        "artifacts ($($Vm2Def.vmName)) ...") -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm2Def -Assertions {
        param($sshClient)
        Invoke-VmReadyAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
        Invoke-StaticNetworkAssertions -SshClient $sshClient -VmDef $Vm2Def
        Invoke-EgressAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
        Invoke-NoJdkVmAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
        Invoke-NoDotnetSdkVmAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
    }
}
