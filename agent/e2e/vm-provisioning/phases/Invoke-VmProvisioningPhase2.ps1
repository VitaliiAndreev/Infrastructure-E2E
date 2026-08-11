<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Common.PowerShell, the assertion helpers, and the shared
    orchestrator helpers are loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-VmProvisioningPhase2
#   Phase 2 - uninstall-via-null on VM1, add VM2 (no javaDevKit), then
#   re-add javaDevKit on VM1 with a different version.
#
#   Sub-phase 2a (first provision):
#     - VM1 entry has javaDevKit = $null (explicit JSON null). This is
#       one of the two reconciler-era "ensure none" signals - the legacy
#       'uninstall: true' sub-field was deleted in feature 42. (Note:
#       dropping the javaDevKit field entirely means "skip this provider",
#       NOT "uninstall" - see Get-JdkDesiredVersions for the rationale.
#       That's why we use explicit null here rather than omitting the
#       field; phase 3b exercises the @() form for symmetry.)
#     - VM2 added with no javaDevKit (field absent => skip provider; the
#       freshly created VM has nothing to skip, so the end state is
#       "no JDK").
#     - One provision run executes both changes - the regression-catching
#       shape: a JDK removal on VM1 must not leak any JDK step onto a
#       freshly created VM2 in the same run.
#
#   Sub-phase 2b (second provision):
#     - VM1 entry gains javaDevKit = { temurin / $JdkReinstallVersion }.
#     - VM2 entry unchanged.
#     - Proves the reconciler installs from scratch when desired moves
#       from empty -> a single version (the "reinstall after removal"
#       scenario from feature 42's plan).
#
#   Under ToolchainsFlow=ansible the sections 2/3 `toolchains` block carries
#   forward unchanged through both sub-phases. It has no removal direction (the
#   apt and docker roles only install), so its lifecycle here is idempotence:
#   the flow re-runs against an already-satisfied declaration and 2a re-asserts
#   the tools are still present at their pins. VM2 gets the complementary
#   witness in both sub-phases - it declares no block, so it must stay clean.
#
#   VM1's `files` array is carried forward unchanged from phase 1 across
#   both sub-phases so the bulk-files plan's idempotence assertion still
#   has snapshot data to validate against. envVars narrow to one entry
#   in 2a (forces a content-change rewrite, so the mtime-advance check
#   below has signal) and stay narrowed in 2b (no churn there).
# ---------------------------------------------------------------------------

function Invoke-VmProvisioningPhase2 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Config,
        [Parameter(Mandatory)] [PSCustomObject] $Vm1Def,
        [Parameter(Mandatory)] [PSCustomObject] $Vm2Def,

        # Timing context threaded from the runner-lifecycle 'Phase 2 +
        # reassert' span. When supplied, each sub-phase shell-out below
        # (provision + toolchains) records as a nested child span with its
        # OWN per-invocation output path, so provision.ps1's and
        # provision-toolchains.sh's exported trees graft in separately rather
        # than clobbering each other on one shared path (feature 88 E2) - the
        # same clobber that hid the real provision cost in Phase 1's report.
        # The standalone vm-provisioning flow passes none; a throwaway tree
        # then absorbs the spans so the wrapping stays uniform.
        [object] $Tree = $null
    )

    if ($null -eq $Tree) {
        $Tree = New-TimingSpanTree -RootName 'vm-provisioning-phase2'
    }

    $tcx = Get-ToolchainPhaseContext -Config $Config
    # Independent file-transport engine axis - see the note in phase 1.
    $fcx = Get-FilesPhaseContext -Config $Config
    $jdkParams        = $tcx.Params.Jdk
    $sdkParams        = $tcx.Params.Sdk
    $toolParams       = $tcx.Params.Tools
    $toolInstallExtra = $tcx.Params.ToolInstallExtra

    # 2a removes every toolchain from VM1 (javaDevKit=$null + dotnetSdk=$null,
    # dotnetTools dropped - all "ensure none" signals both engines honour). 2b
    # reinstalls JDK 17 + dotnet SDK 9.0.100 + the tool. The desired state is
    # authored directly in the per-VM VmProvisionerConfig blocks below for both
    # engines - no separate desired-state document.

    Write-Host '' -ForegroundColor Magenta
    Write-Host 'Phase 2a: rewriting VmProvisionerConfig - VM1 javaDevKit=$null + dotnetSdk=$null + add VM2 ...' `
        -ForegroundColor Magenta

    # 2a) VM1 entry: javaDevKit = $null (explicit JSON null is the
    # "ensure none installed" signal in the reconciler contract;
    # ConvertTo-Json renders $null as JSON null which the validator
    # accepts and Get-JdkDesiredVersions maps to @()).
    $vm1Entry = New-VmEntryBase `
        -Config    $Config `
        -VmName    $Vm1Def.vmName `
        -IpAddress $Vm1Def.ipAddress `
        -Password  $Vm1Def.password
    # Explicit JSON null is the "ensure none installed" signal for both engines
    # (ConvertTo-Json renders $null as JSON null; the reconciler's
    # Get-DesiredVersions maps it to @() and the Ansible per-host projection
    # maps an all-empty VM to an empty install set the roles reconcile to an
    # uninstall). dotnetTools is dropped (absent) so the co-tenanted tool is
    # removed alongside its SDK.
    $vm1Entry.javaDevKit = $null
    $vm1Entry.dotnetSdk  = $null
    # Sections 2/3 carry forward UNCHANGED from phase 1 while section 1 is being
    # removed. The apt and docker roles implement no removal, so there is no
    # uninstall direction to exercise here; keeping the declaration stable makes
    # this re-run the idempotence probe instead - the flow runs again against an
    # already-satisfied desired state and the tools must still be there,
    # untouched by the section-1 teardown happening beside them.
    if ($tcx.IsAnsible) {
        $vm1Entry.toolchains = New-ToolchainsTaxonomyBlock
    }
    # Carry the phase-1 files array forward unchanged so the bulk + single
    # idempotence assertions below have something to validate against.
    $vm1Entry.files = @(
        [ordered]@{
            source = $script:FileTransferSource
            target = $script:FileTransferTarget
        },
        [ordered]@{
            pattern   = $script:BulkFileTransferPattern
            targetDir = $script:BulkFileTransferTargetDir
        }
    )
    # envVars: narrow to one entry. BAR_VAR is dropped so the
    # transport's desired-vs-existing compare sees a content
    # difference - the block must be rewritten (proves the
    # skip-unchanged path does not falsely skip a real change).
    $vm1Entry.envVars = [ordered]@{
        blockName = $script:EnvVarsBlockName
        entries   = @(
            [ordered]@{ name = $script:EnvVarsFooHome.Name; value = $script:EnvVarsFooHome.Value }
        )
    }

    # VM2 entry: no javaDevKit, no files. Plain VM creation so we can
    # observe that no JDK step touched it (B-assertions).
    $vm2Entry = New-VmEntryBase `
        -Config    $Config `
        -VmName    $Vm2Def.vmName `
        -IpAddress $Vm2Def.ipAddress `
        -Password  $Vm2Def.password

    Write-VmProvisionerConfig -Entries @($vm1Entry, $vm2Entry)

    Write-Host 'Phase 2a: provisioning (uninstall via absent on VM1, create VM2) ...' `
        -ForegroundColor Magenta
    Measure-ChildProcessTimingSpan -Tree $Tree -Name '2a provision' -Action {
        Invoke-ProvisionerForPhase -Config $Config -Tcx $tcx -Fcx $fcx
    }

    # Ansible flow: re-transport VM1's carried-forward `files` array so the
    # idempotence assertions below have a second pass to validate (no-op under
    # custom-powershell, which re-copied inside provision.ps1). Precedes the
    # toolchains driver, as at every site.
    Measure-ChildProcessTimingSpan -Tree $Tree -Name '2a files' -Action {
        Set-VmFilesForTest `
            -FilesFlow       $fcx.Flow `
            -ProvisionerPath $Config.ProvisionerPath `
            -WslDistro       $fcx.WslDistro
    }

    # Ansible flow: drive the uninstall by reconciling the (now empty) per-VM
    # toolchain state from VmProvisionerConfig (no-op under custom-powershell,
    # which already uninstalled inside provision.ps1).
    Measure-ChildProcessTimingSpan -Tree $Tree -Name '2a toolchains' -Action {
        Set-VmToolchainsForTest `
            -ToolchainsFlow  $tcx.Flow `
            -ProvisionerPath $Config.ProvisionerPath `
            -WslDistro       $tcx.WslDistro
    }

    Write-Host "Phase 2a: verifying uninstall-via-absent on $($Vm1Def.vmName) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm1Def -Assertions {
        param($sshClient)
        Invoke-VmReadyAssertions -SshClient $sshClient -VmName $Vm1Def.vmName
        Invoke-StaticNetworkAssertions -SshClient $sshClient -VmDef $Vm1Def
        Invoke-EgressAssertions -SshClient $sshClient -VmName $Vm1Def.vmName
        Invoke-JdkUninstallAssertions `
            -SshClient     $sshClient `
            -VmName        $Vm1Def.vmName `
            @jdkParams

        Invoke-DotnetSdkUninstallAssertions `
            -SshClient     $sshClient `
            -VmName        $Vm1Def.vmName `
            @sdkParams

        # dotnetTools entry was dropped from VM1's JSON in this phase
        # (the SDK is being uninstalled, so co-tenanted tools must go
        # too). Asserts the walker / provider combination left no
        # orphaned store dir, symlink, or manifest behind. This is the
        # E2E backing for plan step 7 step 4's "regression guard for the
        # walker" - a future regression that left tool manifests behind
        # after a parent SDK uninstall would fail U3.
        Invoke-DotnetToolsUninstallAssertions `
            -SshClient $sshClient `
            -VmName    $Vm1Def.vmName `
            -ToolId    $script:DotnetToolId `
            -Command   $script:DotnetToolCommand `
            @toolParams

        # Sections 2/3 idempotence: the same declaration went through the flow
        # a second time, so the pinned apt packages and the docker daemon must
        # still be present at the same pins. A role that reinstalled
        # destructively (or an apt pin that lost to a drifted-ahead build on
        # the re-run) fails here rather than silently converging.
        if ($tcx.IsAnsible) {
            Invoke-ToolchainAptInstallAssertions `
                -SshClient $sshClient `
                -VmName    $Vm1Def.vmName `
                -Packages  $script:ToolchainAptPackages

            Invoke-ToolchainBatsLibsInstallAssertions `
                -SshClient $sshClient `
                -VmName    $Vm1Def.vmName `
                -Libraries $script:ToolchainBatsLibs

            Invoke-DockerInstallAssertions `
                -SshClient $sshClient `
                -VmName    $Vm1Def.vmName
        }

        # Idempotence: re-run the file-transfer assertions on the
        # re-provisioned VM. The phase-1 snapshots assert that nothing
        # externally visible about the file targets changed across the
        # re-provision (file contents and mode), per the bulk-files plan.
        Invoke-FileTransferAssertions `
            -SshClient    $sshClient `
            -VmName       $Vm1Def.vmName `
            -SourcePath   $script:FileTransferSource `
            -TargetPath   $script:FileTransferTarget `
            -ExpectedHash $script:Phase1SingleSha | Out-Null

        Invoke-BulkFileTransferAssertions `
            -SshClient     $sshClient `
            -VmName        $Vm1Def.vmName `
            -SourceDir     $script:BulkFileTransferSourceDir `
            -TargetDir     $script:BulkFileTransferTargetDir `
            -BaseNames     $script:BulkFileTransferBaseNames `
            -ExpectedShas  $script:Phase1BulkShas | Out-Null

        # envVars: E1, E2, E3 (MARKER survived), E4' (FOO_HOME still in
        # the block, BAR_VAR's removed). The function also re-checks
        # pam_env (E5) for the still-present FOO_HOME, which doubles
        # as a regression guard: a transport bug that broke the file
        # mid-rewrite would show up as a missing pam_env value here.
        Invoke-EnvVarsAppliedAssertions `
            -SshClient          $sshClient `
            -VmName             $Vm1Def.vmName `
            -BlockName          $script:EnvVarsBlockName `
            -ExpectedEntries    @($script:EnvVarsFooHome) `
            -ExpectedMarkerLine $script:EnvVarsMarkerLine

        # Explicitly check BAR_VAR is gone from any line (E4'). The
        # applied-assertions function only checks that the entries we
        # passed in are present; absence of removed entries is the
        # complementary half.
        Assert-EtcEnvironmentLineAbsent `
            -SshClient $sshClient -VmName $Vm1Def.vmName `
            -Pattern   "^$($script:EnvVarsBarVar.Name)="

        # E6: file mtime advanced versus phase 1's snapshot. Proves the
        # transport rewrote the block (BAR_VAR removal forced the
        # desired != existing branch).
        Assert-EtcEnvironmentMtimeAdvanced `
            -SshClient $sshClient -VmName $Vm1Def.vmName
    }

    Write-Host "Phase 2a: verifying VM2 has no JDK / dotnet artifacts ($($Vm2Def.vmName)) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm2Def -Assertions {
        param($sshClient)
        Invoke-VmReadyAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
        Invoke-StaticNetworkAssertions -SshClient $sshClient -VmDef $Vm2Def
        Invoke-EgressAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
        # VM2 "no leak" witness: VM2 carries no toolchain fields, so neither
        # engine installs on it - the reconciler skips it, and the per-host
        # Ansible flow omits it from the resolved map (its playbook lookup
        # defaults to empty). Asserting it clean under BOTH engines is the E2E
        # proof that per-VM targeting holds - a JDK step on VM1 never leaks to
        # a co-provisioned VM2.
        Invoke-NoJdkVmAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
        Invoke-NoDotnetSdkVmAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
        # Sections 2/3 half of the same witness: VM2 carries no `toolchains`
        # block, so the playbook's per-host selectattr must leave it with no apt
        # packages and no docker daemon while VM1 has both. Ansible-only - under
        # custom-powershell neither VM ever gets a section-2/3 install, so the
        # check would prove nothing about targeting.
        if ($tcx.IsAnsible) {
            Invoke-NoToolchainsVmAssertions `
                -SshClient $sshClient `
                -VmName    $Vm2Def.vmName `
                -Packages  $script:ToolchainAptPackages `
                -Libraries $script:ToolchainBatsLibs
        }
    }

    # ------------------------------------------------------------------
    # 2b) Re-add javaDevKit on VM1 (reinstall scenario).
    # ------------------------------------------------------------------
    Write-Host '' -ForegroundColor Magenta
    Write-Host "Phase 2b: rewriting VmProvisionerConfig - VM1 re-adds JDK $($script:JdkReinstallVersion) + dotnet SDK $($script:DotnetReinstallResolvedVersion) ..." `
        -ForegroundColor Magenta

    $vm1Entry = New-VmEntryBase `
        -Config    $Config `
        -VmName    $Vm1Def.vmName `
        -IpAddress $Vm1Def.ipAddress `
        -Password  $Vm1Def.password
    # Re-add the toolchain blocks (JDK 17 + dotnet SDK 9.0.100 on the *other*
    # channel + the tool) so a fresh install (empty -> single version) runs for
    # every provider in one go. Same blocks for both engines; ansible installs
    # them via provision-toolchains.sh (provision.ps1 -SkipToolchains).
    $vm1Entry.javaDevKit = [ordered]@{
        vendor  = $script:JdkTestVendor
        version = $script:JdkReinstallVersion
    }
    $vm1Entry.dotnetSdk = [ordered]@{
        channel = $script:DotnetReinstallChannel
        version = $script:DotnetReinstallResolvedVersion
    }
    # Re-co-tenant the same tool at its initial pin. Phase 3a then
    # version-changes it to $DotnetToolReinstallVersion alongside the
    # SDK version-change so the swap is observable in a single
    # provision run.
    $vm1Entry.dotnetTools = @(
        [ordered]@{
            id      = $script:DotnetToolId
            version = $script:DotnetToolInitialVersion
        }
    )
    # Sections 2/3 carry forward again so VM1's declaration stays stable for
    # the whole phase and the VM2 witness below still has a populated
    # counterpart to be a witness against.
    if ($tcx.IsAnsible) {
        $vm1Entry.toolchains = New-ToolchainsTaxonomyBlock
    }
    # files + envVars carry forward unchanged from 2a so the only diff
    # the reconciler sees is the new javaDevKit field. No mtime-advance
    # assertion here (envVars block content unchanged - the transport
    # legitimately skips the rewrite).
    $vm1Entry.files = @(
        [ordered]@{
            source = $script:FileTransferSource
            target = $script:FileTransferTarget
        },
        [ordered]@{
            pattern   = $script:BulkFileTransferPattern
            targetDir = $script:BulkFileTransferTargetDir
        }
    )
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

    Write-Host 'Phase 2b: provisioning (re-add JDK on VM1) ...' `
        -ForegroundColor Magenta
    Measure-ChildProcessTimingSpan -Tree $Tree -Name '2b provision' -Action {
        Invoke-ProvisionerForPhase -Config $Config -Tcx $tcx -Fcx $fcx
    }

    # Ansible flow: `files` is unchanged again in 2b, so this pass is a second
    # idempotence probe on the transport (no-op under custom-powershell).
    Measure-ChildProcessTimingSpan -Tree $Tree -Name '2b files' -Action {
        Set-VmFilesForTest `
            -FilesFlow       $fcx.Flow `
            -ProvisionerPath $Config.ProvisionerPath `
            -WslDistro       $fcx.WslDistro
    }

    # Ansible flow: reinstall by reconciling VM1's per-VM toolchain state from
    # VmProvisionerConfig (no-op under custom-powershell, which reinstalled
    # inside provision.ps1).
    Measure-ChildProcessTimingSpan -Tree $Tree -Name '2b toolchains' -Action {
        Set-VmToolchainsForTest `
            -ToolchainsFlow  $tcx.Flow `
            -ProvisionerPath $Config.ProvisionerPath `
            -WslDistro       $tcx.WslDistro
    }

    Write-Host "Phase 2b: verifying JDK $($script:JdkReinstallVersion) + dotnet SDK $($script:DotnetReinstallResolvedVersion) reinstalled on $($Vm1Def.vmName) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm1Def -Assertions {
        param($sshClient)
        Invoke-VmReadyAssertions -SshClient $sshClient -VmName $Vm1Def.vmName
        Invoke-EgressAssertions -SshClient $sshClient -VmName $Vm1Def.vmName
        Invoke-JdkInstallAssertions `
            -SshClient        $sshClient `
            -VmName           $Vm1Def.vmName `
            -RequestedVersion $script:JdkReinstallVersion `
            @jdkParams

        Invoke-DotnetSdkInstallAssertions `
            -SshClient       $sshClient `
            -VmName          $Vm1Def.vmName `
            -ResolvedVersion $script:DotnetReinstallResolvedVersion `
            @sdkParams

        Invoke-DotnetToolsInstallAssertions `
            -SshClient   $sshClient `
            -VmName      $Vm1Def.vmName `
            -ToolId      $script:DotnetToolId `
            -ToolVersion $script:DotnetToolInitialVersion `
            -Command     $script:DotnetToolCommand `
            @toolParams @toolInstallExtra
    }

    # VM2 "no leak" witness (see the 2a note): VM2 carries no toolchain fields,
    # so under BOTH engines the JDK 17 re-install on VM1 must not appear on VM2
    # - the per-host Ansible flow omits VM2 from its resolved map exactly as the
    # reconciler skips it.
    Write-Host "Phase 2b: re-verifying VM2 has no JDK / dotnet artifacts ($($Vm2Def.vmName)) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm2Def -Assertions {
        param($sshClient)
        Invoke-NoJdkVmAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
        Invoke-NoDotnetSdkVmAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
        if ($tcx.IsAnsible) {
            Invoke-NoToolchainsVmAssertions `
                -SshClient $sshClient `
                -VmName    $Vm2Def.vmName `
                -Packages  $script:ToolchainAptPackages `
                -Libraries $script:ToolchainBatsLibs
        }
    }
}
