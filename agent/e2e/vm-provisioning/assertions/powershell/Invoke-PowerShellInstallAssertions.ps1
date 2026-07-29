<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Common.PowerShell (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-PowerShellInstallAssertions
#   Asserts the PowerShell (pwsh) toolchain the Common-Ansible powershell role
#   installed landed correctly on the VM.
#
#   Ansible-engine only. The custom-powershell reconciler has no PowerShell
#   provider, so a `powershell` config entry is inert under that engine and the
#   caller gates this call accordingly - see Invoke-VmProvisioningPhase1.
#
#   Section 1 like the jdk / dotnet assertions, so the end state is probed
#   through the manifest store as well as the filesystem:
#     A1 - the ICU runtime is installed. This is the assertion with the
#          sharpest teeth: a stock Ubuntu 24.04 image ships NO ICU, and pwsh
#          aborts at startup without it. The role installs it as a hard
#          prerequisite rather than leaving it to config, so this proves that
#          behaviour rather than the operator's memory.
#     A2 - `pwsh` resolves on the NON-LOGIN PATH and follows to the versioned
#          install dir. Non-login is the case that matters: a CI step's
#          `shell: pwsh` is not a login shell and never sources
#          /etc/profile.d, which is exactly the gap the /usr/local/bin symlink
#          closes.
#     A3 - the interpreter STARTS and reports the requested version. Equality,
#          not a prefix: the role is handed a concrete major.minor.patch by the
#          host-side staging step, so a drifted build means the pin failed.
#          This is the check that catches a pwsh which unpacked perfectly but
#          cannot run.
#     A4 - the profile script carries the unattended-runner opt-outs.
#     A5 - the manifest records the install, so a later uninstall has the
#          precise paths to tear down rather than a glob.
#
#   Throws on the first failure with a message naming the VM and the observed
#   value. The outer try/finally in Invoke-VmProvisioningTest still runs
#   teardown.
# ---------------------------------------------------------------------------

function Invoke-PowerShellInstallAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        # The exact version from the vault entry's powershell.version. The
        # role rejects a loose pin, so this is always major.minor.patch and
        # can be compared for equality rather than as a prefix.
        [Parameter(Mandatory)]
        [string] $RequestedVersion,

        # The apt package supplying ICU. Release-specific (libicu74 on Ubuntu
        # 24.04), matching the role's powershell_native_packages default -
        # a parameter so a distro bump is a call-site change here too, not a
        # silent mismatch.
        [string] $IcuPackage = 'libicu74',

        # Expected on-disk install dir prefix; the resolved pwsh must live
        # under '<prefix><version>'.
        [string] $InstallPrefix = '/opt/powershell-',

        # Manifest store directory, no trailing slash. The Common-Ansible
        # store, not the reconciler's - this toolchain is Ansible-only.
        [string] $ManifestStoreDir = '/var/lib/common-ansible/toolchains/manifests'
    )

    $installDir = "$InstallPrefix$RequestedVersion"

    # A1) ICU present. Checked BEFORE running pwsh so a missing prerequisite
    #     reports as the package it is, rather than as an opaque startup abort
    #     from the interpreter two assertions later.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   ("dpkg-query -W -f='`${Status}' " + $IcuPackage)
    if ($result.ExitStatus -ne 0) {
        throw "dpkg-query for $IcuPackage failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error). The powershell " +
            "role is expected to install it as a native prerequisite - pwsh " +
            "cannot start without ICU."
    }
    $icuStatus = $result.Output.Trim()
    if ($icuStatus -ne 'install ok installed') {
        throw "$IcuPackage is not installed on $VmName (dpkg status " +
            "'$icuStatus'). pwsh would abort at startup with " +
            "'Couldn't find a valid ICU package installed on the system'."
    }
    Write-Host "  [OK] ICU runtime installed: $IcuPackage" -ForegroundColor Green

    # A2) pwsh on the non-login PATH, followed through the symlink to the
    #     versioned install dir.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command 'bash -c ''p=$(command -v pwsh) && readlink -f "$p"'''
    if ($result.ExitStatus -ne 0) {
        throw "command -v pwsh (non-login shell) failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error). A CI step's " +
            "'shell: pwsh' would fail the same way."
    }
    $pwshPath = $result.Output.Trim()
    $expectedBin = "$installDir/pwsh"
    if ($pwshPath -ne $expectedBin) {
        throw "pwsh on the non-login PATH for $VmName resolved (after " +
            "symlink follow) to '$pwshPath', expected '$expectedBin'."
    }
    Write-Host "  [OK] non-login PATH pwsh: $pwshPath" -ForegroundColor Green

    # A3) The interpreter starts and reports the pinned version. Runs with
    #     -NoProfile so the answer is the interpreter's own, not something a
    #     profile script exported.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command ('pwsh -NoProfile -NonInteractive -Command ' +
                  '''$PSVersionTable.PSVersion.ToString()''')
    if ($result.ExitStatus -ne 0) {
        throw "pwsh failed to start on $VmName (exit $($result.ExitStatus)). " +
            "stdout: $($result.Output)  stderr: $($result.Error)"
    }
    $reportedVersion = $result.Output.Trim()
    if ($reportedVersion -ne $RequestedVersion) {
        throw "pwsh on $VmName reports version '$reportedVersion', expected " +
            "the pinned '$RequestedVersion'. The staged build and the " +
            "installed one disagree."
    }
    Write-Host "  [OK] pwsh runs and reports $reportedVersion" `
        -ForegroundColor Green

    # A4) profile.d opt-outs. Login-shell scope only by design, so this reads
    #     the file rather than sourcing a shell and inspecting the env.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient -Command 'cat /etc/profile.d/powershell.sh'
    if ($result.ExitStatus -ne 0) {
        throw "Reading /etc/profile.d/powershell.sh failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $profileBody = $result.Output
    foreach ($optOut in @('POWERSHELL_TELEMETRY_OPTOUT=1',
                          'POWERSHELL_UPDATECHECK=Off')) {
        if ($profileBody -notmatch [regex]::Escape($optOut)) {
            throw "/etc/profile.d/powershell.sh on $VmName is missing " +
                "'$optOut'. Body: $profileBody"
        }
    }
    Write-Host '  [OK] profile.d carries both unattended opt-outs' `
        -ForegroundColor Green

    # A5) Manifest records what the install owns. Read as raw JSON and
    #     converted host-side so the assertions below are ordinary object
    #     access rather than shell text wrangling.
    $manifestPath = "$ManifestStoreDir/powershell-$RequestedVersion.json"
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient -Command "sudo cat $manifestPath"
    if ($result.ExitStatus -ne 0) {
        throw "Reading the PowerShell manifest '$manifestPath' failed on " +
            "$VmName (exit $($result.ExitStatus)): $($result.Error)"
    }

    try {
        $manifest = $result.Output | ConvertFrom-Json
    }
    catch {
        throw "The PowerShell manifest '$manifestPath' on $VmName is not " +
            "valid JSON: $($result.Output)"
    }

    # ConvertFrom-Json returns $null for empty input WITHOUT throwing, so an
    # empty manifest slips past the catch above and would otherwise surface
    # as a confusing "records name ''" from the field checks below. Name the
    # real problem instead.
    if ($null -eq $manifest) {
        throw "The PowerShell manifest '$manifestPath' on $VmName is empty. " +
            "The host-push pattern writes it LAST, so an empty or absent " +
            "manifest means the install did not complete."
    }

    if ($manifest.name -ne 'powershell') {
        throw "Manifest '$manifestPath' on $VmName records name " +
            "'$($manifest.name)', expected 'powershell'."
    }
    if ($manifest.version -ne $RequestedVersion) {
        throw "Manifest '$manifestPath' on $VmName records version " +
            "'$($manifest.version)', expected '$RequestedVersion'."
    }
    if ($manifest.install_dir -ne $installDir) {
        throw "Manifest '$manifestPath' on $VmName records install_dir " +
            "'$($manifest.install_dir)', expected '$installDir'."
    }
    # The single symlink is what makes pwsh reachable from a non-login shell,
    # and recording it is what lets uninstall remove exactly that path.
    $symlinkPaths = @($manifest.symlinks | ForEach-Object { $_.path })
    if ($symlinkPaths -notcontains '/usr/local/bin/pwsh') {
        throw "Manifest '$manifestPath' on $VmName does not record the " +
            "/usr/local/bin/pwsh symlink. Recorded: $($symlinkPaths -join ', ')"
    }
    $manifestSummary = "$($manifest.name) $($manifest.version) at " +
        $manifest.install_dir
    Write-Host "  [OK] manifest records $manifestSummary" -ForegroundColor Green
}
