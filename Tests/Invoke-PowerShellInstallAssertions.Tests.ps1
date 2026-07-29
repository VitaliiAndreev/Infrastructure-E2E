BeforeAll {
    # Stub the Common.PowerShell cmdlet before dot-sourcing the file under
    # test so Pester can Mock it without the real module loaded.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    $assertionsDir = "$PSScriptRoot\..\agent\e2e\vm-provisioning\assertions"
    . "$assertionsDir\powershell\Invoke-PowerShellInstallAssertions.ps1"

    # Result shape Invoke-SshClientCommand returns on the wire.
    function New-SshResult {
        param([string] $Output = '', [int] $ExitStatus = 0)
        [PSCustomObject]@{ ExitStatus = $ExitStatus; Output = $Output; Error = '' }
    }

    # The manifest the Common-Ansible host-push pattern writes for a
    # PowerShell install. Only the fields the assertion reads are populated.
    function New-PowerShellManifestJson {
        param(
            [string] $Name        = 'powershell',
            [string] $Version     = '7.6.4',
            [string] $InstallDir  = '/opt/powershell-7.6.4',
            [string] $SymlinkPath = '/usr/local/bin/pwsh'
        )
        @{
            schema_version = 1
            name           = $Name
            version        = $Version
            install_dir    = $InstallDir
            symlinks       = @(
                @{ path = $SymlinkPath; target = "$InstallDir/pwsh" }
            )
            profile_script = 'powershell'
            owned_files    = @()
        } | ConvertTo-Json -Depth 5
    }

    # Green-path answers for every probe the assertion makes. Rule order
    # matters: several probes mention 'pwsh', so each is matched on its
    # distinguishing verb.
    function New-PowerShellInstallRules {
        param(
            [string] $IcuStatus      = 'install ok installed',
            [string] $ResolvedPath   = '/opt/powershell-7.6.4/pwsh',
            [string] $ReportedVersion = '7.6.4',
            [string] $ProfileBody    = "export POWERSHELL_TELEMETRY_OPTOUT=1`nexport POWERSHELL_UPDATECHECK=Off`n",
            # Empty (not $null) is the "use the default manifest" signal: a
            # [string] parameter coerces $null to '', so a $null default with
            # a `-eq $null` test would never fire and every green-path case
            # would silently probe an empty manifest.
            [string] $ManifestJson   = ''
        )
        if ([string]::IsNullOrEmpty($ManifestJson)) {
            $ManifestJson = New-PowerShellManifestJson
        }
        @(
            @{ Match = 'dpkg-query*';   Output = $IcuStatus }
            @{ Match = '*command -v*';  Output = $ResolvedPath }
            @{ Match = '*PSVersionTable*'; Output = $ReportedVersion }
            @{ Match = '*profile.d*';   Output = $ProfileBody }
            @{ Match = '*manifests*';   Output = $ManifestJson }
        )
    }
}

Describe 'Invoke-PowerShellInstallAssertions' {

    BeforeEach {
        # Silence the [OK] progress lines; the tests assert on the issued
        # probes and the throw/no-throw outcome, not on console output.
        Mock Write-Host {}
        $script:IssuedCommands = @()
        Mock Invoke-SshClientCommand {
            $script:IssuedCommands += $Command
            foreach ($rule in $script:SshRules) {
                if ($Command -like $rule.Match) { return New-SshResult $rule.Output }
            }
            return New-SshResult ''
        }
    }

    Context 'green path' {

        It 'passes when ICU is installed, pwsh runs, and the manifest matches' {
            $script:SshRules = New-PowerShellInstallRules

            { Invoke-PowerShellInstallAssertions -SshClient ([object]::new()) `
                -VmName 'vm1' -RequestedVersion '7.6.4' } | Should -Not -Throw
        }

        # Non-login is the case that matters: a CI step's `shell: pwsh` never
        # sources /etc/profile.d, so a check that only passed in a login shell
        # would miss exactly the failure this whole feature exists to prevent.
        It 'probes the PATH in a non-login shell' {
            $script:SshRules = New-PowerShellInstallRules

            Invoke-PowerShellInstallAssertions -SshClient ([object]::new()) `
                -VmName 'vm1' -RequestedVersion '7.6.4'

            $pathProbe = $script:IssuedCommands | Where-Object { $_ -like '*command -v pwsh*' }
            $pathProbe | Should -Not -BeNullOrEmpty
            $pathProbe | Should -BeLike 'bash -c*'
            $pathProbe | Should -Not -BeLike '*bash -lc*'
        }

        # -NoProfile keeps the reported version the interpreter's own answer
        # rather than something a profile script exported.
        It 'runs pwsh without a profile' {
            $script:SshRules = New-PowerShellInstallRules

            Invoke-PowerShellInstallAssertions -SshClient ([object]::new()) `
                -VmName 'vm1' -RequestedVersion '7.6.4'

            ($script:IssuedCommands | Where-Object { $_ -like '*PSVersionTable*' }) |
                Should -BeLike '*-NoProfile*'
        }
    }

    Context 'ICU prerequisite' {

        # The sharpest assertion in the family: a stock Ubuntu 24.04 ships no
        # ICU and pwsh aborts at startup without it, so this proves the role
        # installed it rather than the operator having remembered to.
        It 'throws when the ICU package is not installed' {
            $script:SshRules = New-PowerShellInstallRules -IcuStatus 'unknown ok not-installed'

            { Invoke-PowerShellInstallAssertions -SshClient ([object]::new()) `
                -VmName 'vm1' -RequestedVersion '7.6.4' } |
                Should -Throw -ExpectedMessage '*ICU*'
        }

        It 'throws when dpkg-query itself fails' {
            $script:SshRules = @()
            Mock Invoke-SshClientCommand {
                if ($Command -like 'dpkg-query*') { return New-SshResult 'no packages found' 1 }
                return New-SshResult ''
            }

            { Invoke-PowerShellInstallAssertions -SshClient ([object]::new()) `
                -VmName 'vm1' -RequestedVersion '7.6.4' } |
                Should -Throw -ExpectedMessage '*dpkg-query*'
        }

        # Checked before pwsh is ever run, so a missing prerequisite reports
        # as the package it is rather than as an opaque interpreter abort.
        It 'checks ICU before attempting to run pwsh' {
            $script:SshRules = New-PowerShellInstallRules -IcuStatus 'unknown ok not-installed'

            { Invoke-PowerShellInstallAssertions -SshClient ([object]::new()) `
                -VmName 'vm1' -RequestedVersion '7.6.4' } | Should -Throw

            ($script:IssuedCommands | Where-Object { $_ -like '*PSVersionTable*' }) |
                Should -BeNullOrEmpty
        }

        It 'honours a custom ICU package name for a different distro release' {
            $script:SshRules = New-PowerShellInstallRules

            Invoke-PowerShellInstallAssertions -SshClient ([object]::new()) `
                -VmName 'vm1' -RequestedVersion '7.6.4' -IcuPackage 'libicu70'

            ($script:IssuedCommands | Where-Object { $_ -like 'dpkg-query*' }) |
                Should -BeLike '*libicu70*'
        }
    }

    Context 'interpreter' {

        It 'throws when pwsh cannot start' {
            $script:SshRules = New-PowerShellInstallRules
            Mock Invoke-SshClientCommand {
                $script:IssuedCommands += $Command
                if ($Command -like '*PSVersionTable*') {
                    return New-SshResult 'Process terminated.' 1
                }
                foreach ($rule in $script:SshRules) {
                    if ($Command -like $rule.Match) { return New-SshResult $rule.Output }
                }
                return New-SshResult ''
            }

            { Invoke-PowerShellInstallAssertions -SshClient ([object]::new()) `
                -VmName 'vm1' -RequestedVersion '7.6.4' } |
                Should -Throw -ExpectedMessage '*failed to start*'
        }

        # Equality, not a prefix: the role is handed a concrete version by the
        # staging step, so a drifted build means the pin did not hold.
        It 'throws when the reported version is not the pinned one' {
            $script:SshRules = New-PowerShellInstallRules -ReportedVersion '7.5.9'

            { Invoke-PowerShellInstallAssertions -SshClient ([object]::new()) `
                -VmName 'vm1' -RequestedVersion '7.6.4' } |
                Should -Throw -ExpectedMessage "*reports version '7.5.9'*"
        }

        It 'throws when pwsh resolves outside the versioned install dir' {
            $script:SshRules = New-PowerShellInstallRules -ResolvedPath '/usr/bin/pwsh'

            { Invoke-PowerShellInstallAssertions -SshClient ([object]::new()) `
                -VmName 'vm1' -RequestedVersion '7.6.4' } |
                Should -Throw -ExpectedMessage '*/usr/bin/pwsh*'
        }
    }

    Context 'profile script' {

        It 'throws when an unattended opt-out is missing' {
            $script:SshRules = New-PowerShellInstallRules `
                -ProfileBody 'export POWERSHELL_TELEMETRY_OPTOUT=1'

            { Invoke-PowerShellInstallAssertions -SshClient ([object]::new()) `
                -VmName 'vm1' -RequestedVersion '7.6.4' } |
                Should -Throw -ExpectedMessage '*POWERSHELL_UPDATECHECK=Off*'
        }
    }

    Context 'manifest' {

        It 'throws when the manifest records a different version' {
            $script:SshRules = New-PowerShellInstallRules `
                -ManifestJson (New-PowerShellManifestJson -Version '7.5.9')

            { Invoke-PowerShellInstallAssertions -SshClient ([object]::new()) `
                -VmName 'vm1' -RequestedVersion '7.6.4' } |
                Should -Throw -ExpectedMessage '*records version*'
        }

        It 'throws when the manifest records a different install dir' {
            $script:SshRules = New-PowerShellInstallRules `
                -ManifestJson (New-PowerShellManifestJson -InstallDir '/opt/pwsh')

            { Invoke-PowerShellInstallAssertions -SshClient ([object]::new()) `
                -VmName 'vm1' -RequestedVersion '7.6.4' } |
                Should -Throw -ExpectedMessage '*records install_dir*'
        }

        # The symlink is what makes pwsh reachable from a non-login shell, and
        # recording it is what lets uninstall remove exactly that path.
        It 'throws when the manifest does not record the pwsh symlink' {
            $script:SshRules = New-PowerShellInstallRules `
                -ManifestJson (New-PowerShellManifestJson -SymlinkPath '/usr/local/bin/other')

            { Invoke-PowerShellInstallAssertions -SshClient ([object]::new()) `
                -VmName 'vm1' -RequestedVersion '7.6.4' } |
                Should -Throw -ExpectedMessage '*symlink*'
        }

        It 'throws when the manifest is not valid JSON' {
            $script:SshRules = New-PowerShellInstallRules -ManifestJson 'not json {'

            { Invoke-PowerShellInstallAssertions -SshClient ([object]::new()) `
                -VmName 'vm1' -RequestedVersion '7.6.4' } |
                Should -Throw -ExpectedMessage '*not*valid JSON*'
        }

        # ConvertFrom-Json returns $null for empty input without throwing, so
        # this case escapes the JSON catch and needs its own guard - otherwise
        # it reports as a confusing "records name ''" field mismatch.
        It 'throws naming the incomplete install when the manifest is empty' {
            $script:SshRules = @(
                @{ Match = 'dpkg-query*';      Output = 'install ok installed' }
                @{ Match = '*command -v*';     Output = '/opt/powershell-7.6.4/pwsh' }
                @{ Match = '*PSVersionTable*'; Output = '7.6.4' }
                @{ Match = '*profile.d*';      Output = "POWERSHELL_TELEMETRY_OPTOUT=1`nPOWERSHELL_UPDATECHECK=Off" }
                @{ Match = '*manifests*';      Output = '' }
            )

            { Invoke-PowerShellInstallAssertions -SshClient ([object]::new()) `
                -VmName 'vm1' -RequestedVersion '7.6.4' } |
                Should -Throw -ExpectedMessage '*is empty*did not complete*'
        }
    }
}
