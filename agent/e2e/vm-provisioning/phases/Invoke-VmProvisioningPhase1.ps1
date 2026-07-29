<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Common.PowerShell, the assertion helpers, and the shared
    orchestrator helpers (New-VmEntryBase, Write-VmProvisionerConfig,
    Invoke-WithVmSshClient, Measure-ChildProcessTimingSpan) are loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-VmProvisioningPhase1
#   Phase 1 - install JDK 21 on VM1 (plus single-file and bulk-pattern
#   file-transfer fixtures), then re-provision with the same JSON to
#   prove the reconciler's no-op branch.
#
#   Single-VM VmProvisionerConfig so the baseline install path is
#   isolated from any multi-VM interaction. The mixed files array (one
#   single entry + one bulk entry) exercises per-entry dispatch in
#   Invoke-VmPostProvisioning end-to-end. Phase 2 re-provisions the same
#   VM with the same files array to assert idempotence (file contents
#   and mode unchanged), so the VM-side SHA-256s are captured here into
#   $script:Phase1*Shas and consumed there.
#
#   Under ToolchainsFlow=ansible the entry also carries the sections 2/3
#   `toolchains` taxonomy block (pinned apt packages + the docker daemon), and
#   this phase asserts that end state alongside the section-1 one. That block
#   has no custom-powershell counterpart, so it is authored and asserted on the
#   ansible branch only; phase 2 re-runs the flow against the same declaration
#   as the idempotence proof.
#
#   The same ansible-only branch carries a `powershell` entry. It is section 1
#   like the JDK and SDK - host-staged tarball, manifest-reconciled - but the
#   reconciler has no PowerShell provider, so it too would advertise a
#   toolchain nothing installs under custom-powershell. Co-tenanting all three
#   host-pushed toolchains on VM1 is deliberate: it proves one staging run
#   resolves, verifies, and serves three different upstreams without their
#   archive names or manifests colliding.
#
#   The no-op rerun at the end snapshots the JDK artifact mtimes after the
#   first provision, calls provision.ps1 again with the SAME JSON, and
#   asserts the mtimes did not move. A regression where the JdkProvider
#   re-extracts unconditionally would only fail here.
# ---------------------------------------------------------------------------

function Invoke-VmProvisioningPhase1 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Config,
        [Parameter(Mandatory)] [PSCustomObject] $Vm1Def,

        # Optional timing context threaded from the parent orchestration
        # (the 'provisioning Phase 1' part span in Invoke-VmUsersSetup).
        # When supplied, the toolchains shell-out below records as a nested
        # 'provision toolchains' span with its OWN per-invocation output
        # path, so the bash driver's exported tree grafts separately from
        # provision.ps1's export (which the parent part already imports).
        # Without the split, the two co-resident exporting children would
        # share the part's single TIMING_TREE_OUTPUT_PATH and the second
        # writer would clobber the first (feature 88 E2). The standalone
        # provisioning flow passes none; a throwaway tree then absorbs the
        # span so the wrapping stays uniform and nothing downstream reads it.
        [object] $Tree = $null
    )

    if ($null -eq $Tree) {
        $Tree = New-TimingSpanTree -RootName 'vm-provisioning-phase1'
    }

    Write-Host '' -ForegroundColor Magenta
    Write-Host "Phase 1: writing single-VM VmProvisionerConfig (VM1 + JDK $($script:JdkInitialVersion) + dotnet SDK $($script:DotnetInitialResolvedVersion)) ..." `
        -ForegroundColor Magenta

    # Toolchain engine for this run (ansible default, or custom-powershell
    # from the deployment payload). $tcx bundles the flow, the branch boolean,
    # the engine-specific assertion params, and the WSL distro.
    $tcx = Get-ToolchainPhaseContext -Config $Config
    # Splat-ready engine params for this phase's assertions (reconciler
    # defaults under custom-powershell; the common-ansible store + prefix
    # under ansible). Splatting needs simple variables, hence the locals.
    $jdkParams        = $tcx.Params.Jdk
    $sdkParams        = $tcx.Params.Sdk
    $toolParams       = $tcx.Params.Tools
    $toolInstallExtra = $tcx.Params.ToolInstallExtra

    $entry = New-VmEntryBase `
        -Config    $Config `
        -VmName    $Vm1Def.vmName `
        -IpAddress $Vm1Def.ipAddress `
        -Password  $Vm1Def.password
    # Toolchain blocks: JDK 21 + dotnet SDK 8.0.100 + one global tool. The same
    # per-VM desired state feeds both engines - custom-powershell installs them
    # via provision.ps1's reconciler; ansible leaves them for
    # provision-toolchains.sh (provision.ps1 runs -SkipToolchains). Both read
    # these fields from VmProvisionerConfig.
    $entry.javaDevKit = [ordered]@{
        vendor  = $script:JdkTestVendor
        version = $script:JdkInitialVersion
    }
    # Co-tenant the dotnet SDK on VM1 from phase 1. Running JDK + dotnetSdk
    # through the same provision exercises the reconciler's multi-provider
    # dispatch order (JdkProvider then DotnetSdkProvider per Get-Providers) and
    # proves the two providers do not interfere with each other's manifest
    # writes.
    $entry.dotnetSdk = [ordered]@{
        channel = $script:DotnetInitialChannel
        version = $script:DotnetInitialResolvedVersion
    }
    # Co-tenant a single .NET global tool from phase 1. Together with dotnetSdk
    # above this drives DotnetToolsProvider end-to-end through the
    # nested-provider walker contract: SDK installs first, then the tool
    # installs against the host-prefetched .nupkg, and the SDK manifest's
    # children array gains a reference to the tool manifest.
    $entry.dotnetTools = @(
        [ordered]@{
            id      = $script:DotnetToolId
            version = $script:DotnetToolInitialVersion
        }
    )
    # Sections 2 and 3 of the toolchain taxonomy (apt packages + the docker
    # daemon). Ansible-only: the PowerShell reconciler has no section-2/3
    # concept, so declaring the block under custom-powershell would advertise
    # tools nothing installs. Under ansible the playbook selects this block off
    # vm_provisioner_config by matching vmName to inventory_hostname - VM2 never
    # gets one, which is what makes it the witness for that targeting.
    if ($tcx.IsAnsible) {
        $entry.toolchains = New-ToolchainsTaxonomyBlock
        # PowerShell is section 1 (host-pushed) but, like the taxonomy block
        # above, is ansible-only: the reconciler has no PowerShell provider, so
        # declaring it under custom-powershell would advertise a toolchain
        # nothing installs. Co-tenanting it with the JDK and .NET SDK on VM1 is
        # the point - three host-pushed toolchains through one staging run
        # proves the stage step resolves and serves them all without their
        # archive names or manifests colliding.
        $entry.powershell = [ordered]@{
            version = $script:PowerShellVersion
        }
    }
    # Mixed files array: one single entry + one bulk entry. JSON order is
    # preserved by the per-entry dispatch in Invoke-VmPostProvisioning;
    # asserting both forms in one provision run covers the "mixed dispatch"
    # acceptance criterion from docs/dev/implementation/07 - ci jars.
    $entry.files = @(
        [ordered]@{
            source = $script:FileTransferSource
            target = $script:FileTransferTarget
        },
        [ordered]@{
            pattern   = $script:BulkFileTransferPattern
            targetDir = $script:BulkFileTransferTargetDir
        }
    )
    # envVars: write a managed block with two entries. Phases 2 / 3
    # narrow this to one entry and then to empty - the three states
    # cover write / re-write / remove on the same VM.
    $entry.envVars = [ordered]@{
        blockName = $script:EnvVarsBlockName
        entries   = @(
            [ordered]@{ name = $script:EnvVarsFooHome.Name; value = $script:EnvVarsFooHome.Value },
            [ordered]@{ name = $script:EnvVarsBarVar.Name;  value = $script:EnvVarsBarVar.Value }
        )
    }

    Write-VmProvisionerConfig -Entries @($entry)

    Write-Host 'Phase 1: provisioning router + VM1 ...' -ForegroundColor Magenta
    # Own child span so provision.ps1's exported tree (host network, disk
    # acquisition, VM creation, wait-for-SSH, post-provisioning) grafts under
    # a dedicated 'provision' node on its OWN output path. Without this, the
    # no-op rerun below (custom-powershell only) writes provision.ps1's tree a
    # second time to the shared parent path and CLOBBERS this real provision -
    # the report then shows VM creation SKIPPED and buries the ~real creation
    # cost as unaccounted parent time (feature 88 E2).
    Measure-ChildProcessTimingSpan -Tree $Tree -Name 'provision' -Action {
        Invoke-ProvisionerForPhase -Config $Config -Tcx $tcx
    }

    # provision.ps1 ran in its own scope and the discovered router IP
    # never made it back to the test's local _RouterVm reference. Look
    # it up again via Hyper-V KVP so the workload SSH jump (this phase's
    # post-condition checks below, and phases 2 / 3 - the same Vm1Def
    # carries forward) has a populated ipAddress to dial.
    Resolve-RouterIpFromKvp -RouterVmDef $Vm1Def._RouterVm

    # Under the ansible flow, install the toolchains via
    # provision-toolchains.sh now that provision.ps1 has brought the router
    # + VM1 up (it reads the same javaDevKit / dotnetSdk / dotnetTools fields
    # from VmProvisionerConfig). A no-op under custom-powershell (the reconciler
    # already installed them inside provision.ps1 above).
    #
    # Wrapped in its own child-process span so the bash driver's exported
    # timing tree grafts under a nested 'provision toolchains' node with a
    # fresh output path, distinct from provision.ps1's export that the parent
    # part imports - the two exporting children no longer share one path
    # (feature 88 E2). Under custom-powershell the dispatcher shells out to
    # nothing, so the span renders empty. Inert until E3 bridges the opt-in
    # across the WSL boundary; harmless structural addition until then.
    Measure-ChildProcessTimingSpan -Tree $Tree -Name 'provision toolchains' -Action {
        Set-VmToolchainsForTest `
            -ToolchainsFlow  $tcx.Flow `
            -ProvisionerPath $Config.ProvisionerPath `
            -WslDistro       $tcx.WslDistro
    }

    # Router-side white-box checks (forwarding, nftables/dnsmasq, NAT
    # rules, priv0 IP) are no longer asserted here: provision.ps1's
    # Assert-RouterReady runs them during provisioning and fails the run
    # if the router is not ready, so this suite inherits that coverage by
    # invoking provision.ps1 above rather than re-probing the router.

    Write-Host "Phase 1: verifying post-conditions on $($Vm1Def.vmName) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm1Def -Assertions {
        param($sshClient)

        Invoke-VmReadyAssertions -SshClient $sshClient -VmName $Vm1Def.vmName

        Invoke-StaticNetworkAssertions -SshClient $sshClient -VmDef $Vm1Def

        # Egress through the router. Runs before any opt-in install
        # assertion so a network regression surfaces before JDK /
        # dotnet failures that depend on the same egress.
        Invoke-EgressAssertions -SshClient $sshClient -VmName $Vm1Def.vmName

        Invoke-JdkInstallAssertions `
            -SshClient        $sshClient `
            -VmName           $Vm1Def.vmName `
            -RequestedVersion $script:JdkInitialVersion `
            @jdkParams

        Invoke-DotnetSdkInstallAssertions `
            -SshClient       $sshClient `
            -VmName          $Vm1Def.vmName `
            -ResolvedVersion $script:DotnetInitialResolvedVersion `
            @sdkParams

        # Tool install assertions follow the SDK install assertions
        # because I5 reads the parent SDK manifest (reconciler flow) - the
        # SDK assertions have already verified that manifest is present and
        # well-formed at this point. Under ansible, @toolInstallExtra carries
        # -SkipReconcilerManifestSchema so the content + walker checks (which
        # that engine does not produce) are bypassed.
        Invoke-DotnetToolsInstallAssertions `
            -SshClient   $sshClient `
            -VmName      $Vm1Def.vmName `
            -ToolId      $script:DotnetToolId `
            -ToolVersion $script:DotnetToolInitialVersion `
            -Command     $script:DotnetToolCommand `
            @toolParams @toolInstallExtra

        # The ansible-only toolchains, asserted only where they exist: both
        # PowerShell and the sections-2/3 block are authored above under
        # ansible alone, so under custom-powershell there is nothing installed
        # to check. Runs after the jdk / dotnet assertions so a regression in
        # that older, more load-bearing path surfaces first.
        if ($tcx.IsAnsible) {
            # PowerShell first among these: it is the section-1 sibling of the
            # jdk / dotnet checks just above, so it belongs with them rather
            # than after the section-2/3 group.
            Invoke-PowerShellInstallAssertions `
                -SshClient        $sshClient `
                -VmName           $Vm1Def.vmName `
                -RequestedVersion $script:PowerShellVersion `
                -IcuPackage       $script:PowerShellIcuPackage

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

        # Capture VM-side SHA-256s so phase 2 can assert idempotence by
        # snapshot. Helpers also assert C2-C5 (single) / C1-C4 (bulk)
        # against the host source on the way past.
        $script:Phase1SingleSha = Invoke-FileTransferAssertions `
            -SshClient  $sshClient `
            -VmName     $Vm1Def.vmName `
            -SourcePath $script:FileTransferSource `
            -TargetPath $script:FileTransferTarget

        $script:Phase1BulkShas = Invoke-BulkFileTransferAssertions `
            -SshClient $sshClient `
            -VmName    $Vm1Def.vmName `
            -SourceDir $script:BulkFileTransferSourceDir `
            -TargetDir $script:BulkFileTransferTargetDir `
            -BaseNames $script:BulkFileTransferBaseNames

        # envVars: E1, E2, E4, E5. -ExpectedMarkerLine is intentionally
        # omitted here because the marker is seeded AFTER these
        # assertions pass - VM1 does not exist before phase 1 so there
        # is no opportunity to seed it pre-provision (see
        # docs/dev/implementation/08 - env vars/plan.md step 5).
        Invoke-EnvVarsAppliedAssertions `
            -SshClient        $sshClient `
            -VmName           $Vm1Def.vmName `
            -BlockName        $script:EnvVarsBlockName `
            -ExpectedEntries  @($script:EnvVarsFooHome, $script:EnvVarsBarVar)

        # Seed MARKER_OUTSIDE outside the managed block and snapshot
        # the resulting mtime. Phases 2 and 3 use both: phase 2 to
        # assert the re-write left the marker alone AND advanced the
        # mtime, phase 3 to assert removal left the marker alone.
        Set-VmEnvironmentMarkerAndSnapshotMtime `
            -SshClient $sshClient -VmName $Vm1Def.vmName

        # Snapshot the JDK artifacts AFTER the install assertions pass
        # so the no-op rerun below can prove the reconciler did not
        # touch them. Reconciler-only: the no-op rerun probes provision.ps1's
        # diff branch, but under ansible provision.ps1 runs -SkipToolchains so
        # the reconciler never touches toolchains and there is no no-op branch
        # to probe. Capture the snapshots only when they will be consumed.
        if (-not $tcx.IsAnsible) {
            $script:Phase1JdkSnapshot = Get-JdkArtifactSnapshot `
                -SshClient     $sshClient `
                -VmName        $Vm1Def.vmName `
                -InstallPrefix $script:JdkInstallPrefix

            # Same snapshot for the dotnet SDK so the no-op rerun proves
            # the DotnetSdkProvider also took the diff's no-op branch.
            $script:Phase1DotnetSnapshot = Get-DotnetSdkArtifactSnapshot `
                -SshClient     $sshClient `
                -VmName        $Vm1Def.vmName `
                -InstallPrefix $script:DotnetInstallPrefix
        }
    }

    # No-op rerun. Same VmProvisionerConfig already on disk - the
    # reconciler must take the diff's no-op branch for every artifact. This
    # asserts a property of the PowerShell reconciler (re-provision does not
    # re-extract unchanged toolchains); under ansible provision.ps1 runs
    # -SkipToolchains, so re-running it never touches toolchains and there is
    # no equivalent no-op branch to probe - the
    # ansible flow is done after its install assertions above.
    if ($tcx.IsAnsible) { return }

    Write-Host 'Phase 1: re-provisioning VM1 with unchanged JSON (no-op) ...' `
        -ForegroundColor Magenta
    # Separate child span from the real 'provision' above so this rerun's tree
    # (VM creation / disk SKIPPED - the idempotency proof) lands on its own path
    # and does not overwrite the real provision's timings. Reached only under
    # custom-powershell; the ansible flow returned above before this rerun.
    Measure-ChildProcessTimingSpan -Tree $Tree -Name 'provision (no-op rerun)' -Action {
        Invoke-ProvisionerForPhase -Config $Config -Tcx $tcx
    }

    Write-Host "Phase 1: verifying no-op rerun did not touch JDK / dotnet artifacts ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm1Def -Assertions {
        param($sshClient)
        Invoke-JdkNoopAssertions `
            -SshClient        $sshClient `
            -VmName           $Vm1Def.vmName `
            -InstallPrefix    $script:JdkInstallPrefix `
            -PreviousSnapshot $script:Phase1JdkSnapshot

        Invoke-DotnetSdkNoopAssertions `
            -SshClient        $sshClient `
            -VmName           $Vm1Def.vmName `
            -InstallPrefix    $script:DotnetInstallPrefix `
            -PreviousSnapshot $script:Phase1DotnetSnapshot
    }
}
