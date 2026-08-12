<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Common.PowerShell (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-EnvVarsAppliedAssertions
#   Asserts that the managed envVars block requested via VmProvisionerConfig
#   landed in /etc/environment on the VM with the expected content and
#   ownership, and (when -ExpectedMarkerLine is supplied) that an
#   operator-seeded out-of-block line still exists outside the BEGIN / END
#   span.
#
#   Used by phase 1 (initial write, no marker yet) and phase 2 (re-write
#   with a single entry remaining and the marker seeded between phases).
#   Phase 3's "block removed" shape lives in
#   Invoke-EnvVarsRemovedAssertions because the assertion set diverges
#   enough (no markers, no entries) that one switch-laden function would
#   obscure intent.
#
#   $ExpectedEntries are { Name, Value } objects (PSCustomObjects /
#   hashtables). Order matters only for clarity in error messages; the
#   transport groups them together inside the managed block but does not
#   guarantee a particular order line-by-line.
#
#   Throws on the first failure with a message naming the VM and the
#   observed value. The outer try/finally in Invoke-VmProvisioningTest
#   still runs teardown.
# ---------------------------------------------------------------------------

function Invoke-EnvVarsAppliedAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName,

        # BlockName the managed block was written under. Must match the
        # `envVars.blockName` field in the VM config used by the current
        # phase - any drift here means the assertion is checking a
        # different block than the one the provisioner wrote.
        [Parameter(Mandatory)] [string] $BlockName,

        # Array of { Name, Value } objects describing the entries the
        # block must contain. Passed by the caller so the same assertion
        # function covers phase 1 (two entries) and phase 2 (one entry).
        [Parameter(Mandatory)]
        [object[]] $ExpectedEntries,

        # Optional `NAME="value"` line that must remain present outside
        # the BEGIN / END span. Seeded by phase 1 after the first managed-
        # block write; checked in phase 2 (and again in phase 3 via the
        # removed-assertions sibling). Omit on phase 1 since the marker
        # is seeded only after the assertions pass.
        [string] $ExpectedMarkerLine
    )

    # 1) Ownership + mode (E1). /etc/environment is read by pam_env at
    #    login; root:root 0644 is the standard Ubuntu default the
    #    transport must preserve.
    Assert-EtcEnvironmentOwnershipAndMode -SshClient $SshClient -VmName $VmName

    # 2) BEGIN / END markers exist exactly once each (E2). Two of either
    #    would mean a previous run left a duplicate block behind - a bug
    #    the transport must not produce.
    $beginLine = Get-EtcEnvironmentMarkerLine `
        -SshClient $SshClient -VmName $VmName `
        -Marker "# BEGIN $BlockName"
    $endLine = Get-EtcEnvironmentMarkerLine `
        -SshClient $SshClient -VmName $VmName `
        -Marker "# END $BlockName"
    if ($beginLine -ge $endLine) {
        throw "envVars markers misordered on $VmName for block '$BlockName' " +
            "(BEGIN at line $beginLine, END at line $endLine)."
    }
    Write-Host "  [OK] block '$BlockName' present (lines $beginLine..$endLine)" `
        -ForegroundColor Green

    # 3) Out-of-block marker preserved (E3). Skipped on phase 1 (no
    #    marker seeded yet).
    if ($PSBoundParameters.ContainsKey('ExpectedMarkerLine') -and $ExpectedMarkerLine) {
        Assert-EtcEnvironmentOutOfBlockLine `
            -SshClient    $SshClient `
            -VmName       $VmName `
            -ExpectedLine $ExpectedMarkerLine `
            -BeginLine    $beginLine `
            -EndLine      $endLine
    }

    # 4) Each expected entry appears exactly once, INSIDE the block
    #    span (E4 / E4'). Line-number check catches an accidental
    #    rewrite that duplicated the entry outside the block.
    foreach ($entry in $ExpectedEntries) {
        $escaped = $entry.Value.Replace('\', '\\').Replace('"', '\"')
        $expected = "$($entry.Name)=`"$escaped`""
        $entryLine = Get-EtcEnvironmentLineNumber `
            -SshClient $SshClient -VmName $VmName -Line $expected
        if ($entryLine -le $beginLine -or $entryLine -ge $endLine) {
            throw "envVars entry '$($entry.Name)' on $VmName is outside the " +
                "managed block (entry at line $entryLine, block spans " +
                "$beginLine..$endLine)."
        }
        Write-Host "  [OK] entry $($entry.Name) inside block (line $entryLine)" `
            -ForegroundColor Green
    }

    # 5) pam_env view (E5). Each fresh SSH login session triggers PAM,
    #    which loads /etc/environment. Renci.SshNet's SshClient runs
    #    exec channels under PAM (UsePAM=yes is the Ubuntu default),
    #    so printenv inside this session reflects the post-write file.
    #    This is the user-visible reason the feature exists - a file
    #    that parses correctly but is unreadable to pam_env defeats the
    #    point.
    foreach ($entry in $ExpectedEntries) {
        Assert-VmEnvVarVisibleToPamEnv `
            -SshClient $SshClient `
            -VmName    $VmName `
            -Name      $entry.Name `
            -Value     $entry.Value
    }
}

# Helper: plant a line INSIDE the managed block, between the sentinels.
#
# Not an assertion - it is the setup half of the engine hand-off case. The
# hand-off runs the engine that did NOT write the block and then re-checks the
# block, but every one of those checks passes on a run where that engine did
# nothing, because the state it verifies was already correct. This gives the
# second engine work only a real run can do: a line it never declared, sitting
# where only its own markers say it may write. Removing it requires finding the
# other engine's sentinels and rewriting what is between them, which is exactly
# the interchangeability the two engines claim.
#
# `sed -i` with the BEGIN marker as the address and `a` appends on the line
# after it, so the probe lands inside the span rather than beside it. Anchored
# with ^...$ so a marker name that is a prefix of another block's cannot match.
function Add-EtcEnvironmentBlockProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName,
        [Parameter(Mandatory)] [string] $BlockName,
        [Parameter(Mandatory)] [string] $ProbeLine
    )

    $marker = "# BEGIN $BlockName"
    $cmd = "sudo sed -i '\\%^$marker`$% a $ProbeLine' /etc/environment"
    $result = Invoke-SshClientCommand -SshClient $SshClient -Command $cmd
    if ($result.ExitStatus -ne 0) {
        throw "Failed to plant the hand-off probe on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }

    # Confirm it actually landed. A sed address that matched nothing exits 0
    # and changes nothing, which would make the hand-off check vacuous again -
    # in exactly the way this probe exists to prevent.
    $verify = Invoke-SshClientCommand -SshClient $SshClient `
        -Command "grep -c -Fx '$ProbeLine' /etc/environment"
    $count = if ($verify.ExitStatus -eq 0) { [int]$verify.Output.Trim() } else { 0 }
    if ($count -ne 1) {
        throw "Hand-off probe did not land inside block '$BlockName' on $VmName " +
            "($count occurrence(s); expected 1). The BEGIN marker was not found."
    }
    Write-Host "  [OK] hand-off probe planted inside block '$BlockName'" `
        -ForegroundColor Green
}

# Helper: ensure /etc/environment ownership is root:root and mode 0644.
# Extracted so the removed-assertions sibling can reuse the same E1 check.
function Assert-EtcEnvironmentOwnershipAndMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName
    )

    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "stat -c '%U:%G %a' /etc/environment"
    if ($result.ExitStatus -ne 0) {
        throw "stat on /etc/environment failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $parts = $result.Output.Trim() -split '\s+'
    $owner = $parts[0]
    $mode  = $parts[1]
    if ($owner -ne 'root:root') {
        throw "/etc/environment owner mismatch on $VmName " +
            "(expected 'root:root', got '$owner')."
    }
    if ($mode -ne '644') {
        throw "/etc/environment mode mismatch on $VmName " +
            "(expected '644', got '$mode')."
    }
    Write-Host "  [OK] /etc/environment owner=$owner mode=$mode" -ForegroundColor Green
}

# Helper: return the (unique) line number of $Marker in /etc/environment,
# or throw with the observed count. Single grep -n -F so the marker text
# is treated as a fixed string (no regex metachar surprises).
function Get-EtcEnvironmentMarkerLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName,
        [Parameter(Mandatory)] [string] $Marker
    )

    # grep -c -F counts fixed-string matches; -n with grep alone gives line
    # numbers. We do both: count for uniqueness, line number for ordering.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "grep -c -Fx '$Marker' /etc/environment"
    $count = if ($result.ExitStatus -eq 0) { [int]$result.Output.Trim() }
             elseif ($result.ExitStatus -eq 1) { 0 }
             else { throw "grep -c failed on $VmName " +
                    "(exit $($result.ExitStatus)): $($result.Error)" }
    if ($count -ne 1) {
        throw "envVars marker '$Marker' on $VmName appeared $count times in " +
            "/etc/environment (expected exactly 1)."
    }

    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "grep -n -Fx '$Marker' /etc/environment | head -n 1 | cut -d: -f1"
    if ($result.ExitStatus -ne 0) {
        throw "grep -n on marker '$Marker' failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    return [int]$result.Output.Trim()
}

# Helper: return the (unique) line number of $Line in /etc/environment.
# Used to confirm entries sit between the BEGIN / END markers.
function Get-EtcEnvironmentLineNumber {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName,
        [Parameter(Mandatory)] [string] $Line
    )

    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "grep -c -Fx '$Line' /etc/environment"
    $count = if ($result.ExitStatus -eq 0) { [int]$result.Output.Trim() }
             elseif ($result.ExitStatus -eq 1) { 0 }
             else { throw "grep -c failed on $VmName " +
                    "(exit $($result.ExitStatus)): $($result.Error)" }
    if ($count -ne 1) {
        throw "envVars line '$Line' on $VmName appeared $count times in " +
            "/etc/environment (expected exactly 1)."
    }

    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "grep -n -Fx '$Line' /etc/environment | head -n 1 | cut -d: -f1"
    if ($result.ExitStatus -ne 0) {
        throw "grep -n on '$Line' failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    return [int]$result.Output.Trim()
}

# Helper: assert $ExpectedLine appears outside the BEGIN..END span. The
# line-number diff (rather than a bare grep count) catches a transport
# bug that duplicates the line inside the block on re-write.
function Assert-EtcEnvironmentOutOfBlockLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName,
        [Parameter(Mandatory)] [string] $ExpectedLine,
        [Parameter(Mandatory)] [int]    $BeginLine,
        [Parameter(Mandatory)] [int]    $EndLine
    )

    $markerLine = Get-EtcEnvironmentLineNumber `
        -SshClient $SshClient -VmName $VmName -Line $ExpectedLine
    if ($markerLine -gt $BeginLine -and $markerLine -lt $EndLine) {
        throw "Out-of-block line on $VmName was relocated INSIDE the managed " +
            "block (line $markerLine, block spans $BeginLine..$EndLine): " +
            "'$ExpectedLine'."
    }
    Write-Host "  [OK] out-of-block line preserved (line $markerLine)" `
        -ForegroundColor Green
}

# Helper: assert pam_env loaded the value into the SSH session's
# environment. printenv with no expansion returns the raw value, so the
# comparison is byte-equal against the host-side string.
function Assert-VmEnvVarVisibleToPamEnv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Value
    )

    # printenv exits 1 when the variable is unset. Either result is
    # interesting - we want a clear message instead of an empty match.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "printenv $Name"
    if ($result.ExitStatus -ne 0) {
        throw "Env var '$Name' not visible to pam_env on $VmName " +
            "(printenv exit $($result.ExitStatus)). Likely cause: " +
            "/etc/environment wrote but PAM session did not pick it up."
    }
    $observed = $result.Output.TrimEnd("`r", "`n")
    if ($observed -ne $Value) {
        throw "Env var '$Name' on $VmName has wrong pam_env value " +
            "(expected '$Value', got '$observed')."
    }
    Write-Host "  [OK] pam_env sees $Name='$observed'" -ForegroundColor Green
}
