BeforeAll {
    # Shared timing doubles (New-/Measure-TimingSpan, the bare Import-Timing
    # SpanTree, New-ImportedTreeDouble). The Common.PowerShell timing surface is
    # not installed in this unit runspace; the REAL Measure-ChildProcessTiming
    # Span comes from dot-sourcing the provisioning chain below.
    . "$PSScriptRoot\support\TimingSpanTestDoubles.ps1"

    # The chain's only top-level side effect is an Invoke-ModuleInstall for
    # Posh-SSH at dot-source time. Stub it so loading the file under test does
    # not reach the network.
    function Invoke-ModuleInstall { param($ModuleName) }

    # Normally set by Initialize-E2EEnvironment, which is not in the chain;
    # referenced at parse scope by Invoke-ProvisionerForPhase (Mocked here).
    $script:E2ETestSecretSuffix = 'TEST'

    . "$PSScriptRoot\..\agent\e2e\vm-provisioning\Invoke-VmProvisioningTest.ps1"

    # Runs the phase against the fixture config and returns the child span names
    # under the part, in creation order. Defined in BeforeAll, not the Describe
    # body: the body runs at discovery, whose scope the It blocks cannot see.
    function Get-PhaseSpanName {
        $tree = New-TimingSpanTree -RootName 'run'
        Measure-ChildProcessTimingSpan -Tree $tree -Name 'Phase 2 + reassert' -Action {
            Invoke-VmProvisioningPhase2 `
                -Config $script:config -Vm1Def $script:vm1Def -Vm2Def $script:vm2Def -Tree $tree
        }
        $part = $tree.Root.Children | Where-Object { $_.Name -eq 'Phase 2 + reassert' }
        return @($part.Children | ForEach-Object { $_.Name })
    }
}

# ---------------------------------------------------------------------------
# Phase 2 runs two sub-phases (2a uninstall-via-absent, 2b reinstall), each of
# which shells out three times: provision.ps1, then the files driver, then the
# toolchains driver. These tests cover that dispatch surface only - the on-VM
# assertions live behind Invoke-WithVmSshClient, which is Mocked away.
# ---------------------------------------------------------------------------

Describe 'Invoke-VmProvisioningPhase2 engine dispatch' {

    BeforeEach {
        Remove-Item Env:TIMING_TREE_OUTPUT_PATH -ErrorAction SilentlyContinue

        Mock Write-Host {}

        # Leaf boundaries the phase crosses. None writes a timing export, so
        # Measure-ChildProcessTimingSpan's Test-Path guard means the bare
        # Import-TimingSpanTree double is never reached.
        Mock Write-VmProvisionerConfig  { }
        Mock Invoke-WithVmSshClient     { }   # skips all SSH-side assertions
        Mock Invoke-ProvisionerForPhase { }
        Mock Set-VmFilesForTest         { }
        Mock Set-VmToolchainsForTest    { }
        Mock Set-VmEnvVarsForTest       { }
        Mock Invoke-EnvVarsEngineHandoff { }
        # Probe planting is gated on the predicate and reaches the VM over SSH;
        # both are mocked so this suite stays about dispatch, not about the
        # cross-engine case (covered where the hand-off itself is tested).
        Mock Test-EnvVarsHandoffAvailable { $true }
        Mock Add-EtcEnvironmentBlockProbe { }

        # Only the fields the phase reads before its first Mocked boundary:
        # New-VmEntryBase reads TestVm.ubuntuVersion / vmConfigPath / vhdPath
        # plus the VM identity; the two phase contexts read the flows and distro.
        $script:config = [pscustomobject]@{
            ProvisionerPath = 'C:\fake\Vm-Provisioner'
            ToolchainsFlow  = 'ansible'
            FilesFlow       = 'ansible'
            EnvVarsFlow     = 'ansible'
            WslDistro       = 'Ubuntu-24.04'
            TestVm          = [pscustomobject]@{
                ubuntuVersion = '24.04'
                vmConfigPath  = 'C:\fake\vmconfig'
                vhdPath       = 'C:\fake\vhd'
            }
        }
        $script:vm1Def = [pscustomobject]@{
            vmName = 'e2e-test-1'; ipAddress = '10.99.0.10'; password = 'pw'
        }
        $script:vm2Def = [pscustomobject]@{
            vmName = 'e2e-test-2'; ipAddress = '10.99.0.11'; password = 'pw'
        }
    }

    It 'wraps every sub-phase shell-out in its own child span, files before toolchains' {
        # Each exporting child needs its own TIMING_TREE_OUTPUT_PATH or the
        # later writer clobbers the earlier one. The order also encodes the
        # engine contract: files are transported before toolchains install,
        # matching the menu and the in-line PowerShell sequence.
        Get-PhaseSpanName | Should -Be @(
            '2a provision', '2a files', '2a toolchains', '2a env',
            '2b provision', '2b files', '2b toolchains', '2b env')
    }

    It 'calls the files dispatcher before the toolchains dispatcher in each sub-phase' {
        # Asserted directly as well as through the span names, so a future
        # refactor that stopped wrapping the calls in spans would still be held
        # to the ordering.
        $script:calls = [System.Collections.Generic.List[string]]::new()
        Mock Set-VmFilesForTest      { $script:calls.Add('files') }
        Mock Set-VmToolchainsForTest { $script:calls.Add('toolchains') }
        Mock Set-VmEnvVarsForTest    { $script:calls.Add('env') }

        Get-PhaseSpanName | Out-Null

        $script:calls | Should -Be @(
            'files', 'toolchains', 'env',
            'files', 'toolchains', 'env')
    }

    It 'drives the files dispatcher once per sub-phase with the session flow and distro' {
        Get-PhaseSpanName | Out-Null

        Should -Invoke Set-VmFilesForTest -Exactly -Times 2 -ParameterFilter {
            $FilesFlow -eq 'ansible' -and
            $ProvisionerPath -eq 'C:\fake\Vm-Provisioner' -and
            $WslDistro -eq 'Ubuntu-24.04'
        }
    }

    It 'hands the provisioner every engine context on every provision' {
        Get-PhaseSpanName | Out-Null

        # Both sub-phase provisions carry all three session contexts.
        Should -Invoke Invoke-ProvisionerForPhase -Exactly -Times 2 -ParameterFilter {
            $Fcx.IsAnsible -and $Tcx.IsAnsible -and $Ecx.IsAnsible
        }
    }

    It 'runs the engine hand-off once, in 2a only' {
        # The cross-engine check: after 2a wrote the block with the session's
        # engine, the opposite one re-applies it and the phase re-asserts.
        # Once, not per sub-phase - 2b changes nothing about the block, so a
        # second hand-off would re-prove the same thing at the same cost.
        Get-PhaseSpanName | Out-Null

        Should -Invoke Invoke-EnvVarsEngineHandoff -Exactly -Times 1 `
            -ParameterFilter { $Ecx.IsAnsible }
    }

    It 'resolves the two engine axes independently' {
        # The pairing that proves neither dispatcher reads the other's flow: an
        # Ansible file transport beside the PowerShell toolchain reconciler.
        $script:config.FilesFlow      = 'ansible'
        $script:config.ToolchainsFlow = 'custom-powershell'

        Get-PhaseSpanName | Out-Null

        Should -Invoke Set-VmFilesForTest -Exactly -Times 2 -ParameterFilter {
            $FilesFlow -eq 'ansible'
        }
        Should -Invoke Set-VmToolchainsForTest -Exactly -Times 2 -ParameterFilter {
            $ToolchainsFlow -eq 'custom-powershell'
        }
        Should -Invoke Invoke-ProvisionerForPhase -Exactly -Times 2 -ParameterFilter {
            $Fcx.IsAnsible -and -not $Tcx.IsAnsible -and $Ecx.IsAnsible
        }
    }

    It 'carries VM1 files forward unchanged into both sub-phases' {
        # The idempotence assertions in 2a and 2b only mean something if the
        # declared entries are identical across the re-provisions; a phase that
        # quietly dropped or rewrote them would make both passes vacuous.
        $script:written = [System.Collections.Generic.List[object]]::new()
        Mock Write-VmProvisionerConfig { $script:written.Add($Entries) }

        Get-PhaseSpanName | Out-Null

        $script:written.Count | Should -Be 2
        # Serialise each write's VM1 `files` array to one string per write -
        # collecting the arrays themselves would flatten both writes into a
        # single four-element list and compare the wrong pairs.
        $filesJsonPerWrite = @($script:written | ForEach-Object {
            ($_ | Where-Object { $_.vmName -eq 'e2e-test-1' }).files |
                ConvertTo-Json -Depth 5 -Compress
        })

        $filesJsonPerWrite.Count | Should -Be 2
        # Single entry + bulk entry, byte-identical across the re-provision.
        $filesJsonPerWrite[0] | Should -Match '"source"'
        $filesJsonPerWrite[0] | Should -Match '"pattern"'
        $filesJsonPerWrite[0] | Should -Be $filesJsonPerWrite[1]
    }
}
