BeforeAll {
    # See Invoke-VmProvisioningPhase2.Tests.ps1 for the fixture rationale - this
    # suite is its peer for the version-change / remove-via-empty phase.
    . "$PSScriptRoot\support\TimingSpanTestDoubles.ps1"

    function Invoke-ModuleInstall { param($ModuleName) }

    $script:E2ETestSecretSuffix = 'TEST'

    . "$PSScriptRoot\..\agent\e2e\vm-provisioning\Invoke-VmProvisioningTest.ps1"

    # Defined in BeforeAll, not the Describe body: the body runs at discovery,
    # whose scope the It blocks cannot see.
    function Get-PhaseSpanName {
        $tree = New-TimingSpanTree -RootName 'run'
        Measure-ChildProcessTimingSpan -Tree $tree -Name 'Phase 3 + reassert' -Action {
            Invoke-VmProvisioningPhase3 `
                -Config $script:config -Vm1Def $script:vm1Def -Vm2Def $script:vm2Def -Tree $tree
        }
        $part = $tree.Root.Children | Where-Object { $_.Name -eq 'Phase 3 + reassert' }
        return @($part.Children | ForEach-Object { $_.Name })
    }
}

# ---------------------------------------------------------------------------
# Phase 3 runs two sub-phases (3a version-change, 3b remove-via-empty). Unlike
# phase 2 it declares no `files` on VM1 at all, which makes it the phase that
# proves the files driver copes with a host that declares nothing - the
# behaviour the vm_files role implements as a no-op on an empty entry list.
# ---------------------------------------------------------------------------

Describe 'Invoke-VmProvisioningPhase3 engine dispatch' {

    BeforeEach {
        Remove-Item Env:TIMING_TREE_OUTPUT_PATH -ErrorAction SilentlyContinue

        Mock Write-Host {}

        Mock Write-VmProvisionerConfig  { }
        Mock Invoke-WithVmSshClient     { }   # skips all SSH-side assertions
        Mock Invoke-ProvisionerForPhase { }
        Mock Set-VmFilesForTest         { }
        Mock Set-VmToolchainsForTest    { }
        Mock Set-VmEnvVarsForTest       { }

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
        Get-PhaseSpanName | Should -Be @(
            '3a provision', '3a files', '3a toolchains', '3a env',
            '3b provision', '3b files', '3b toolchains', '3b env')
    }

    It 'calls the files dispatcher before the toolchains dispatcher in each sub-phase' {
        $script:calls = [System.Collections.Generic.List[string]]::new()
        Mock Set-VmFilesForTest      { $script:calls.Add('files') }
        Mock Set-VmToolchainsForTest { $script:calls.Add('toolchains') }
        Mock Set-VmEnvVarsForTest    { $script:calls.Add('env') }

        Get-PhaseSpanName | Out-Null

        $script:calls | Should -Be @(
            'files', 'toolchains', 'env',
            'files', 'toolchains', 'env')
    }

    It 'still runs the files driver on a phase that declares no files' {
        # The driver is unconditional: a host with an empty entry list is a
        # legitimate state the flow must complete cleanly on, not a case the
        # E2E should route around. Gating the call on "did this phase declare
        # any files" would leave that path unexercised for the whole suite.
        $script:written = [System.Collections.Generic.List[object]]::new()
        Mock Write-VmProvisionerConfig { $script:written.Add($Entries) }

        Get-PhaseSpanName | Out-Null

        $vm1Entries = @($script:written | ForEach-Object {
            $_ | Where-Object { $_.vmName -eq 'e2e-test-1' } })
        $vm1Entries.Count | Should -Be 2
        foreach ($entry in $vm1Entries) { $entry.Contains('files') | Should -BeFalse }

        Should -Invoke Set-VmFilesForTest -Exactly -Times 2
    }

    It 'drives the files dispatcher with the session flow and distro' {
        Get-PhaseSpanName | Out-Null

        Should -Invoke Set-VmFilesForTest -Exactly -Times 2 -ParameterFilter {
            $FilesFlow -eq 'ansible' -and
            $ProvisionerPath -eq 'C:\fake\Vm-Provisioner' -and
            $WslDistro -eq 'Ubuntu-24.04'
        }
    }

    It 'hands the provisioner both engine contexts on every provision' {
        Get-PhaseSpanName | Out-Null

        Should -Invoke Invoke-ProvisionerForPhase -Exactly -Times 2 -ParameterFilter {
            $Fcx.IsAnsible -and $Tcx.IsAnsible
        }
    }

    It 'resolves the two engine axes independently' {
        $script:config.FilesFlow      = 'custom-powershell'
        $script:config.ToolchainsFlow = 'ansible'

        Get-PhaseSpanName | Out-Null

        Should -Invoke Set-VmFilesForTest -Exactly -Times 2 -ParameterFilter {
            $FilesFlow -eq 'custom-powershell'
        }
        Should -Invoke Invoke-ProvisionerForPhase -Exactly -Times 2 -ParameterFilter {
            -not $Fcx.IsAnsible -and $Tcx.IsAnsible
        }
    }
}
