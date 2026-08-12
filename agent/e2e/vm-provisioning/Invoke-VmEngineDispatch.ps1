<#
.NOTES
    The engine-selection body the three provisioning dispatchers share -
    Set-VmFilesForTest, Set-VmToolchainsForTest and Set-VmEnvVarsForTest.

    Each of those owns one axis and differs from its siblings in exactly three
    values: the name of its flow parameter, the ops wrapper it drives, and the
    word it puts in the progress line. Everything around those - what
    custom-powershell means, that the ansible branch needs a bridge, and how
    the failure reads when it has not got one - was the same 23 lines copied
    three times, so it lives here once.

    Deliberately NOT folded into Invoke-VmProvisionerAnsibleOps, which this
    calls. That function's contract is "the caller has already decided the
    ansible engine is selected; this only knows how to cross the boundary",
    and it has callers and tests resting on exactly that. Deciding WHETHER to
    cross is a separate concern and gets a separate function.

    Why the three public dispatchers survive as thin wrappers rather than
    collapsing into one call: their named -<Axis>Flow parameters are what make
    fifteen call sites in the phases readable, and the phase suites mock them
    individually to assert the dispatch ORDER (files, then toolchains, then
    env). One shared function would make those three calls indistinguishable
    without inspecting arguments, trading a real assertion for three saved
    stubs.

    Do not run this file directly. Dot-sourced by the three dispatchers.
#>

# The shared WSL shell-out, pulled in here so a dispatcher gets the whole
# chain by sourcing only its own file - the property its unit tests rely on.
. "$PSScriptRoot\Invoke-VmProvisionerAnsibleOps.ps1"

# ---------------------------------------------------------------------------
# Invoke-VmEngineDispatch
#   Runs one Infrastructure-Vm-Provisioner ops wrapper when the axis is on the
#   ansible engine, and does nothing when it is on custom-powershell (where
#   provision.ps1's in-line path already did that half inside the provision
#   the phase has just run).
# ---------------------------------------------------------------------------

function Invoke-VmEngineDispatch {
    [CmdletBinding()]
    param(
        # The selected engine for this axis, already ValidateSet-checked by
        # the calling dispatcher's own parameter.
        [Parameter(Mandatory)]
        [ValidateSet('custom-powershell', 'ansible')]
        [string] $Flow,

        # The caller's parameter name ('FilesFlow', ...). Only used to build
        # the missing-bridge message, so it names the parameter the operator
        # actually set rather than this function's own.
        [Parameter(Mandatory)]
        [string] $FlowParameterName,

        [Parameter(Mandatory)]
        [string] $ProvisionerPath,

        # Wrapper file name under hyper-v/ubuntu/Ansible/ops/.
        [Parameter(Mandatory)]
        [string] $OpsScript,

        # What the run is doing, for the progress line ('files', ...).
        [Parameter(Mandatory)]
        [string] $Activity,

        # Required for the ansible branch; ignored by custom-powershell, which
        # never crosses the WSL boundary - an operator running the PowerShell
        # engine must not be forced to declare a distro they will not use.
        [Parameter()]
        [string] $WslDistro
    )

    if ($Flow -eq 'custom-powershell') {
        return
    }

    if (-not $WslDistro) {
        throw "${FlowParameterName}=ansible requires -WslDistro"
    }

    Invoke-VmProvisionerAnsibleOps `
        -ProvisionerPath $ProvisionerPath `
        -WslDistro       $WslDistro `
        -OpsScript       $OpsScript `
        -Activity        $Activity
}
