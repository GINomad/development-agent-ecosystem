[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$config = Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
$policy = $config.pipeline.policy

$options = @(
    [pscustomobject][ordered]@{
        mode = 'disabled'
        description = 'Do not monitor, queue, or deliver through pipelines.'
        requiredInformation = @('Explicit confirmation that pipeline integration is not applicable.')
    },
    [pscustomobject][ordered]@{
        mode = 'observe-only'
        description = 'Observe exact-SHA runs and optional pull-request state without pushing or queueing builds.'
        requiredInformation = @('Repository IDs to observe.','Optional observed build definition IDs.','Definitions known to be deployments.','Whether pull-request lifecycle monitoring is wanted.')
    },
    [pscustomobject][ordered]@{
        mode = 'guarded-delivery'
        description = 'Allow reviewed branch delivery and explicitly allowlisted build-only queueing after all review gates pass.'
        requiredInformation = @('Repositories covered by the policy.','Observed build definition IDs.','Ordered build-only definition IDs allowed for auto-queue.','Deployment definition IDs that must never be queued.','Allowed remote and protected base branches.','Pull-request lifecycle preference.')
    }
)

[pscustomobject][ordered]@{
    configurationStatus = [string]$policy.configurationStatus
    mode = [string]$policy.mode
    requiresDecision = [string]$policy.configurationStatus -eq 'unconfigured'
    instruction = if ([string]$policy.configurationStatus -eq 'unconfigured') {
        'Choose one pipeline policy mode, provide its required non-secret information, or explicitly disable pipeline integration.'
    } else {
        "Pipeline policy is $([string]$policy.configurationStatus) in mode '$([string]$policy.mode)'."
    }
    options = $options
}
