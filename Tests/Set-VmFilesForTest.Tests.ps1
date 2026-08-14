BeforeAll {
    # The dispatcher touches no vault: the ansible flow reads its desired state
    # from VmProvisionerConfig (written by the phase), so a plain dot-source with
    # no secret-cmdlet stubs is enough. Pester runs each file in a fresh runspace.
    . "$PSScriptRoot\..\agent\e2e\vm-provisioning\Set-VmFilesForTest.ps1"
}

Describe 'Set-VmFilesForTest' {

    BeforeEach {
        Mock Write-Host {}
        $Script:ProvisionerPath = Join-Path $TestDrive 'Vm-Provisioner'
        New-Item -Path $Script:ProvisionerPath -ItemType Directory -Force | Out-Null
    }

    # ------------------------------------------------------------------
    Context 'FilesFlow=custom-powershell' {
    # ------------------------------------------------------------------

        It 'returns without invoking wsl (the in-line transport already copied)' {
            $Script:wslRan = $false
            function wsl { $Script:wslRan = $true; $global:LASTEXITCODE = 0 }

            Set-VmFilesForTest `
                -FilesFlow       'custom-powershell' `
                -ProvisionerPath $Script:ProvisionerPath

            $Script:wslRan | Should -BeFalse
        }

        It 'does not require WslDistro' {
            # The custom-powershell branch never crosses the WSL boundary, so an
            # operator running the PowerShell engine must not be forced to
            # declare a distro they will not use.
            function wsl { $global:LASTEXITCODE = 0 }

            { Set-VmFilesForTest `
                -FilesFlow       'custom-powershell' `
                -ProvisionerPath $Script:ProvisionerPath
            } | Should -Not -Throw
        }
    }

    # ------------------------------------------------------------------
    Context 'FilesFlow=ansible' {
    # ------------------------------------------------------------------

        It 'drives provision-files.sh from ProvisionerPath (desired state comes from VmProvisionerConfig)' {
            $Script:Captured    = [System.Collections.Generic.List[string]]::new()
            $Script:CapturedCwd = $null
            function wsl {
                foreach ($a in $args) { $Script:Captured.Add([string]$a) }
                $Script:CapturedCwd  = (Get-Location).Path
                $global:LASTEXITCODE = 0
            }

            Set-VmFilesForTest `
                -FilesFlow       'ansible' `
                -ProvisionerPath $Script:ProvisionerPath `
                -WslDistro       'Ubuntu-24.04'

            # `--` is consumed by PowerShell before a function shadow; assert
            # the surrounding tokens, and that cwd anchored at ProvisionerPath
            # (the wrapper path is relative, so it only resolves from there).
            $joined = $Script:Captured -join ' '
            $joined | Should -Match '^-d Ubuntu-24\.04(\s+--)?\s+\./hyper-v/ubuntu/Ansible/ops/provision-files\.sh$'
            $Script:CapturedCwd | Should -Be $Script:ProvisionerPath
        }

        It 'restores the caller location after the driver runs' {
            # Every phase calls this between other location-sensitive steps, so
            # a leaked Push-Location would silently re-root the rest of the run.
            function wsl { $global:LASTEXITCODE = 0 }
            $before = (Get-Location).Path

            Set-VmFilesForTest `
                -FilesFlow       'ansible' `
                -ProvisionerPath $Script:ProvisionerPath `
                -WslDistro       'Ubuntu-24.04'

            (Get-Location).Path | Should -Be $before
        }

        It 'throws when WslDistro is missing' {
            { Set-VmFilesForTest `
                -FilesFlow       'ansible' `
                -ProvisionerPath $Script:ProvisionerPath
            } | Should -Throw '*requires -WslDistro*'
        }

        It 'throws with the exit code when the driver fails' {
            function wsl { $global:LASTEXITCODE = 5 }

            { Set-VmFilesForTest `
                -FilesFlow       'ansible' `
                -ProvisionerPath $Script:ProvisionerPath `
                -WslDistro       'Ubuntu-24.04'
            } | Should -Throw '*exited 5*'
        }
    }

    # ------------------------------------------------------------------
    Context 'invalid FilesFlow' {
    # ------------------------------------------------------------------

        It 'rejects unknown values at parameter binding time' {
            { Set-VmFilesForTest `
                -FilesFlow       'legacy' `
                -ProvisionerPath $Script:ProvisionerPath
            } | Should -Throw '*ValidateSet*'
        }
    }
}
