BeforeAll {
    # Stub the Common.PowerShell cmdlet before dot-sourcing the file under
    # test so Pester can Mock it without the real module loaded.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    $assertionsDir = "$PSScriptRoot\..\agent\e2e\vm-provisioning\assertions"
    . "$assertionsDir\env-vars\Invoke-EnvVarsAppliedAssertions.ps1"

    # Result shape Invoke-SshClientCommand returns on the wire.
    function New-SshResult {
        param([string] $Output = '', [int] $ExitStatus = 0, [string] $ErrorText = '')
        [PSCustomObject]@{ ExitStatus = $ExitStatus; Output = $Output; Error = $ErrorText }
    }
}

# ---------------------------------------------------------------------------
# The probe is planted over SSH with a single `sed -i`, so the only thing a
# unit test can hold is the exact command text. That is worth holding: the
# command's failure mode is a live-VM one (a malformed sed script fails only
# when sed parses it), which makes an E2E run against real hardware the
# cheapest place the defect can otherwise surface.
# ---------------------------------------------------------------------------

Describe 'Add-EtcEnvironmentBlockProbe' {

    BeforeEach {
        # Silence the [OK] progress line; these tests assert on the issued
        # command and the throw/no-throw outcome, not on console output.
        Mock Write-Host {}
        $script:IssuedCommands = @()
        # Default green path: sed succeeds, the verify grep counts one match.
        $script:SedExit    = 0
        $script:GrepOutput = "1`n"
        Mock Invoke-SshClientCommand {
            $script:IssuedCommands += $Command
            if ($Command -like 'sudo sed *') {
                return New-SshResult -ExitStatus $script:SedExit -ErrorText 'sed said no'
            }
            return New-SshResult -Output $script:GrepOutput
        }
    }

    It 'addresses the BEGIN marker with a well-formed sed regex address' {
        { Add-EtcEnvironmentBlockProbe -SshClient ([object]::new()) `
            -VmName 'vm1' -BlockName 'e2e-ci' -ProbeLine 'ZZZ_PROBE="planted"' } |
            Should -Not -Throw

        # `\%REGEXP%` - exactly ONE backslash introduces the custom delimiter.
        # Two would make `\` itself the delimiter and leave the regex unclosed,
        # which sed rejects with "unterminated address regex". `%` (rather than
        # the usual `/`) keeps a block name containing a slash from needing to
        # be escaped.
        $script:IssuedCommands[0] | Should -BeExactly (
            'sudo sed -i ' +
            "'\%^# BEGIN e2e-ci`$% a ZZZ_PROBE=`"planted`"' " +
            '/etc/environment')
    }

    It 'verifies the planted line with a fixed-string grep' {
        { Add-EtcEnvironmentBlockProbe -SshClient ([object]::new()) `
            -VmName 'vm1' -BlockName 'e2e-ci' -ProbeLine 'ZZZ_PROBE="planted"' } |
            Should -Not -Throw

        $script:IssuedCommands[1] | Should -BeExactly (
            "grep -c -Fx 'ZZZ_PROBE=`"planted`"' /etc/environment")
    }

    It 'reports the VM and sed stderr when the edit fails' {
        $script:SedExit = 1

        { Add-EtcEnvironmentBlockProbe -SshClient ([object]::new()) `
            -VmName 'vm1' -BlockName 'e2e-ci' -ProbeLine 'ZZZ_PROBE="planted"' } |
            Should -Throw '*Failed to plant the hand-off probe on vm1*sed said no*'
    }

    It 'rejects a sed address that matched nothing' {
        # sed exits 0 on a non-matching address and changes nothing, so the
        # count is the only signal that the marker was actually found.
        $script:GrepOutput = "0`n"

        { Add-EtcEnvironmentBlockProbe -SshClient ([object]::new()) `
            -VmName 'vm1' -BlockName 'e2e-ci' -ProbeLine 'ZZZ_PROBE="planted"' } |
            Should -Throw '*did not land inside block*0 occurrence(s)*'
    }
}
