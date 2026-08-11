BeforeAll {
    # ----------------------------------------------------------------------
    # Shared timing doubles (New-/Measure-TimingSpan, the bare Import-Timing
    # SpanTree each test Mocks, and New-ImportedTreeDouble). The Common.Power
    # Shell timing surface is not installed in this unit runspace; the fixture
    # header documents the contract they reproduce. The REAL Measure-Child
    # ProcessTimingSpan (both the part span this test drives and the nested
    # 'provision toolchains' span the phase adds) comes from dot-sourcing the
    # provisioning chain below.
    # ----------------------------------------------------------------------
    . "$PSScriptRoot\support\TimingSpanTestDoubles.ps1"

    # The chain's only top-level side effect is an Invoke-ModuleInstall for
    # Posh-SSH at dot-source time. Stub it so loading the file under test does
    # not reach the network (same as Invoke-RunnerLifecycleTest.Tests).
    function Invoke-ModuleInstall { param($ModuleName) }

    # E2ETestSecretSuffix normally comes from Initialize-E2EEnvironment, which
    # is not in the dot-sourced chain; the phase reads it via Invoke-Provisioner
    # ForPhase (Mocked here, but the constant is referenced at parse scope).
    $script:E2ETestSecretSuffix = 'TEST'

    # Dot-source the provisioning chain: this pulls in the REAL phase
    # orchestration (Invoke-VmProvisioningPhase1), the shared helpers it calls
    # (Get-ToolchainPhaseContext, New-VmEntryBase, ...), the $script:* scenario
    # constants, and - since E2 - Measure-ChildProcessTimingSpan. Only the leaf
    # shell-outs are Mocked per-test.
    . "$PSScriptRoot\..\agent\e2e\vm-provisioning\Invoke-VmProvisioningTest.ps1"
}

Describe 'Invoke-VmProvisioningPhase1 toolchains child span' {

    BeforeEach {
        Remove-Item Env:TIMING_TREE_OUTPUT_PATH -ErrorAction SilentlyContinue

        Mock Write-Host {}

        # Config + VM def carrying only the fields the (mostly Mocked) phase
        # reads before its early ansible-flow return: New-VmEntryBase reads
        # TestVm.ubuntuVersion / vmConfigPath / vhdPath and the VM identity;
        # Get-ToolchainPhaseContext reads ToolchainsFlow / WslDistro.
        $script:config = [pscustomobject]@{
            ProvisionerPath = 'C:\fake\Vm-Provisioner'
            ToolchainsFlow  = 'ansible'
            FilesFlow       = 'ansible'
            WslDistro       = 'Ubuntu-24.04'
            TestVm          = [pscustomobject]@{
                ubuntuVersion = '24.04'
                vmConfigPath  = 'C:\fake\vmconfig'
                vhdPath       = 'C:\fake\vhd'
            }
        }
        $script:vm1Def = [pscustomobject]@{
            vmName    = 'e2e-test-1'
            ipAddress = '10.99.0.10'
            password  = 'pw'
            _RouterVm = [pscustomobject]@{}
        }

        # Leaf boundaries the phase crosses, all Mocked so no real work runs.
        # Each exporting child writes a distinguishable marker to whichever
        # opt-in path is active when they run, so the Import mock can hand back
        # the right subtree for each.
        Mock Write-VmProvisionerConfig { }
        Mock Resolve-RouterIpFromKvp   { }
        Mock Invoke-WithVmSshClient    { }   # skips all SSH-side assertions
        Mock Invoke-ProvisionerForPhase {
            Set-Content -LiteralPath $env:TIMING_TREE_OUTPUT_PATH -Value 'provision.ps1'
        }
        Mock Set-VmFilesForTest {
            Set-Content -LiteralPath $env:TIMING_TREE_OUTPUT_PATH -Value 'files'
        }
        Mock Set-VmToolchainsForTest {
            Set-Content -LiteralPath $env:TIMING_TREE_OUTPUT_PATH -Value 'toolchains'
        }

        # Route each import to the subtree matching the marker the child wrote,
        # so the three exports (provision.ps1, the files driver and the
        # toolchains driver) are told apart.
        Mock Import-TimingSpanTree {
            param([string] $Path)
            switch ((Get-Content -LiteralPath $Path -Raw).Trim()) {
                'provision.ps1' { New-ImportedTreeDouble -ChildNames @('boot VM', 'install JDK') }
                'files'         { New-ImportedTreeDouble -ChildNames @('resolve file entries', 'run playbook') }
                'toolchains'    { New-ImportedTreeDouble -ChildNames @('run jdk role', 'run dotnet role') }
                default         { $null }
            }
        }
    }

    It 'grafts the provision, files and toolchains exports under their own child spans' {
        # Drive the phase exactly as Invoke-VmUsersSetup does: inside the
        # 'provisioning Phase 1' part span, threading the same tree in.
        $tree = New-TimingSpanTree -RootName 'run'
        Measure-ChildProcessTimingSpan -Tree $tree -Name 'provisioning Phase 1' -Action {
            Invoke-VmProvisioningPhase1 -Config $script:config -Vm1Def $script:vm1Def -Tree $tree
        }

        $part = $tree.Root.Children | Where-Object { $_.Name -eq 'provisioning Phase 1' }

        # Each shell-out nests under its OWN child span so their exports land on
        # separate output paths - no shared-path clobber. Ansible flow: real
        # provision + files + toolchains, and no no-op rerun (the phase returns
        # before it). Order is load-bearing: files precede toolchains, matching
        # the menu's provision-files -> provision-toolchains sequence.
        @($part.Children | ForEach-Object { $_.Name }) |
            Should -Be @('provision', 'provision files', 'provision toolchains')

        $provision = $part.Children | Where-Object { $_.Name -eq 'provision' }
        @($provision.Children | ForEach-Object { $_.Name }) |
            Should -Be @('boot VM', 'install JDK')

        $files = $part.Children | Where-Object { $_.Name -eq 'provision files' }
        @($files.Children | ForEach-Object { $_.Name }) |
            Should -Be @('resolve file entries', 'run playbook')

        $toolchains = $part.Children | Where-Object { $_.Name -eq 'provision toolchains' }
        @($toolchains.Children | ForEach-Object { $_.Name }) |
            Should -Be @('run jdk role', 'run dotnet role')
    }

    It 'nests provision, empty files / toolchains spans, and the no-op rerun under custom-powershell' {
        # custom-powershell: both dispatchers shell out to nothing, so their
        # spans render empty; the phase then runs the no-op
        # idempotency rerun as its OWN span, kept separate from the real
        # provision so the rerun's tree never clobbers it (the bug this split
        # fixes).
        $script:config.ToolchainsFlow = 'custom-powershell'
        $script:config.FilesFlow      = 'custom-powershell'
        Mock Set-VmFilesForTest { }
        Mock Set-VmToolchainsForTest { }

        $tree = New-TimingSpanTree -RootName 'run'
        Measure-ChildProcessTimingSpan -Tree $tree -Name 'provisioning Phase 1' -Action {
            Invoke-VmProvisioningPhase1 -Config $script:config -Vm1Def $script:vm1Def -Tree $tree
        }

        $part = $tree.Root.Children | Where-Object { $_.Name -eq 'provisioning Phase 1' }

        # Real provision, empty files + toolchains, and the separately-spanned
        # rerun.
        @($part.Children | ForEach-Object { $_.Name }) | Should -Be @(
            'provision', 'provision files', 'provision toolchains',
            'provision (no-op rerun)')

        $files = $part.Children | Where-Object { $_.Name -eq 'provision files' }
        $files.Children.Count | Should -Be 0

        $toolchains = $part.Children | Where-Object { $_.Name -eq 'provision toolchains' }
        $toolchains.Children.Count | Should -Be 0

        # Both the real provision and the rerun keep their own grafted tree -
        # proof neither overwrote the other.
        $provision = $part.Children | Where-Object { $_.Name -eq 'provision' }
        @($provision.Children | ForEach-Object { $_.Name }) |
            Should -Be @('boot VM', 'install JDK')

        $rerun = $part.Children | Where-Object { $_.Name -eq 'provision (no-op rerun)' }
        @($rerun.Children | ForEach-Object { $_.Name }) |
            Should -Be @('boot VM', 'install JDK')
    }

    It 'marks provision toolchains Failed but still keeps the provision span when the driver throws' {
        # Failure path: the toolchains driver throws AFTER the provision span has
        # already exported. The nested wrap must restore the outer path so the
        # real provision's grafted tree survives - proof the restore fires on the
        # throw path too.
        Mock Set-VmToolchainsForTest { throw 'toolchains boom' }

        $tree = New-TimingSpanTree -RootName 'run'
        {
            Measure-ChildProcessTimingSpan -Tree $tree -Name 'provisioning Phase 1' -Action {
                Invoke-VmProvisioningPhase1 -Config $script:config -Vm1Def $script:vm1Def -Tree $tree
            }
        } | Should -Throw '*toolchains boom*'

        $part = $tree.Root.Children | Where-Object { $_.Name -eq 'provisioning Phase 1' }
        $part.Status | Should -Be 'Failed'

        $toolchains = $part.Children | Where-Object { $_.Name -eq 'provision toolchains' }
        $toolchains.Status | Should -Be 'Failed'

        # The real provision span completed before the throw and kept its tree.
        $provision = $part.Children | Where-Object { $_.Name -eq 'provision' }
        $provision.Status | Should -Be 'OK'
        @($provision.Children | ForEach-Object { $_.Name }) |
            Should -Be @('boot VM', 'install JDK')
    }
}

Describe 'Invoke-ProvisionerForPhase engine switches' {
    # The one place either engine axis changes what provision.ps1 is asked to
    # do. A regression that dropped a switch would leave BOTH engines running
    # the same half of the work: the in-line transport would copy the files the
    # Ansible driver is about to copy again, and the E2E would pass anyway
    # because the end state is identical. Only asserting the arguments catches
    # it - hence a real script on disk that records what it was bound to,
    # rather than a Mock of the call.

    BeforeAll {
        # Drives the function for one engine pairing and returns the parameter
        # names provision.ps1 actually bound. Defined in BeforeAll, not in the
        # Describe body: the body runs at discovery, whose scope the It blocks
        # cannot see.
        function Get-BoundProvisionerParam {
            param([bool] $ToolchainsAnsible, [bool] $FilesAnsible)

            Invoke-ProvisionerForPhase `
                -Config $script:provConfig `
                -Tcx ([pscustomobject]@{ IsAnsible = $ToolchainsAnsible }) `
                -Fcx ([pscustomobject]@{ IsAnsible = $FilesAnsible })

            return @(Get-Content -LiteralPath $script:provArgsPath)
        }
    }

    BeforeEach {
        Mock Write-Host {}

        $script:provRoot = Join-Path $TestDrive 'Vm-Provisioner'
        $script:provDir  = Join-Path $script:provRoot 'hyper-v\ubuntu\PowerShell'
        New-Item -Path $script:provDir -ItemType Directory -Force | Out-Null

        # Records the parameter names it was invoked with, one per line, beside
        # itself. $PSScriptRoot resolves to the script's own directory, so the
        # test reads the file back without threading a path through the call.
        $script:provArgsPath = Join-Path $script:provDir 'bound-params.txt'
        Set-Content -LiteralPath (Join-Path $script:provDir 'provision.ps1') -Value @'
param(
    [string] $SecretSuffix,
    [switch] $SkipToolchains,
    [switch] $SkipFiles
)
$PSBoundParameters.Keys |
    Set-Content -LiteralPath (Join-Path $PSScriptRoot 'bound-params.txt')
'@

        $script:provConfig = [pscustomobject]@{ ProvisionerPath = $script:provRoot }
    }

    It 'passes -SkipFiles when the files flow is ansible' {
        Get-BoundProvisionerParam -ToolchainsAnsible $false -FilesAnsible $true |
            Should -Contain 'SkipFiles'
    }

    It 'omits -SkipFiles when the files flow is custom-powershell' {
        Get-BoundProvisionerParam -ToolchainsAnsible $false -FilesAnsible $false |
            Should -Not -Contain 'SkipFiles'
    }

    It 'drives the two axes independently' {
        # The pairing that proves neither switch is derived from the other:
        # ansible toolchains with the in-line file transport still running.
        $bound = Get-BoundProvisionerParam -ToolchainsAnsible $true -FilesAnsible $false
        $bound | Should -Contain 'SkipToolchains'
        $bound | Should -Not -Contain 'SkipFiles'
    }

    It 'passes both switches when both flows are ansible' {
        $bound = Get-BoundProvisionerParam -ToolchainsAnsible $true -FilesAnsible $true
        $bound | Should -Contain 'SkipToolchains'
        $bound | Should -Contain 'SkipFiles'
    }

    It 'always passes the E2E secret suffix' {
        # Named, not positional: an array splat would spill it into
        # provision.ps1's positional slot and fail to bind.
        Get-BoundProvisionerParam -ToolchainsAnsible $true -FilesAnsible $true |
            Should -Contain 'SecretSuffix'
    }
}

Describe 'Get-FilesPhaseContext' {

    It 'reads the flow off the config' {
        $fcx = Get-FilesPhaseContext -Config ([pscustomobject]@{
            FilesFlow = 'custom-powershell'
            WslDistro = 'Ubuntu-24.04'
        })

        $fcx.Flow      | Should -Be 'custom-powershell'
        $fcx.IsAnsible | Should -BeFalse
        $fcx.WslDistro | Should -Be 'Ubuntu-24.04'
    }

    It 'falls back to ansible for a config that omits FilesFlow' {
        # Matches the agent-loop parameter default, so a Config assembled
        # before this axis existed lands on the same engine either way.
        $fcx = Get-FilesPhaseContext -Config ([pscustomobject]@{})

        $fcx.Flow      | Should -Be 'ansible'
        $fcx.IsAnsible | Should -BeTrue
    }

    It 'yields a null WslDistro for a config that omits it' {
        # Strict mode makes an unguarded property read throw; the dispatcher
        # is what rejects the missing distro, with a named error.
        (Get-FilesPhaseContext -Config ([pscustomobject]@{})).WslDistro |
            Should -BeNullOrEmpty
    }
}
