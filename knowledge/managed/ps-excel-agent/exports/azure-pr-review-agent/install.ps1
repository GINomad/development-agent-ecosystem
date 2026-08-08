[CmdletBinding()]
param(
    [string[]] $RepositoryUrl,
    [string[]] $Reviewer,
    [string[]] $IncludeAuthors,
    [string[]] $ExcludeAuthors,
    [ValidateSet('azure-cli','environment')][string] $AzureCredentialMode = 'azure-cli',
    [ValidateSet('gh-cli','environment')][string] $GitHubCredentialMode = 'gh-cli',
    [string] $AzureTokenEnvironmentVariable = 'AZURE_DEVOPS_EXT_PAT',
    [string] $GitHubTokenEnvironmentVariable = 'GH_TOKEN',
    [ValidateRange(5,1440)][int] $PollIntervalMinutes = 60,
    [ValidatePattern('^\d{2}:\d{2}$')][string] $DailyTime = '11:00',
    [string] $InstallRoot = (Join-Path $HOME '.codex\skills'),
    [string] $DataRoot = (Join-Path $env:LOCALAPPDATA 'Codex\azure-pr-review-monitor'),
    [switch] $Force,
    [switch] $SkipAuthentication,
    [switch] $SkipScheduledTasks
)

$ErrorActionPreference = 'Stop'
function Find-CommandPath {
    param([string[]] $Names, [string] $KnownPath, [string] $InstallCommand)
    foreach ($name in $Names) { $command=Get-Command $name -ErrorAction SilentlyContinue|Select-Object -First 1;if($command){return $command.Source} }
    if ($KnownPath -and (Test-Path $KnownPath)) { return $KnownPath }
    throw "Required command was not found. Install it with: $InstallCommand"
}
function Invoke-External {
    param([string] $FilePath, [string[]] $Arguments)
    $old=$ErrorActionPreference;try{$ErrorActionPreference='Continue';& $FilePath @Arguments;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$old}
    if($code -ne 0){throw "$FilePath failed with exit code $code."}
}

$sourceSkill = Join-Path $PSScriptRoot 'skill\azure-pr-review-monitor'
if (-not (Test-Path (Join-Path $sourceSkill 'SKILL.md'))) { throw 'Packaged skill is incomplete.' }
. (Join-Path $sourceSkill 'scripts\agent_config.ps1')
if (-not $RepositoryUrl -or -not @($RepositoryUrl | Where-Object { $_ }).Count) { $RepositoryUrl = @((Read-Host 'Azure DevOps or GitHub repository URL')) }
if (-not $Reviewer -or -not @($Reviewer | Where-Object { $_ }).Count) { $Reviewer = @((Read-Host 'Reviewer identity (Azure email or GitHub login)')) }
if ($Reviewer.Count -notin @(1,$RepositoryUrl.Count)) { throw 'Supply one reviewer for all repositories or one reviewer per repository URL.' }

$gitPath = Find-CommandPath @('git.exe','git') '' 'winget install --exact --id Git.Git'
$codexPath = Find-CommandPath @('codex.exe','codex') '' 'Install Codex CLI or the OpenAI Codex VS Code extension'
$descriptors = @($RepositoryUrl | ForEach-Object { Get-RepositoryDescriptor -Url $_ })
$azPath = $null; $ghPath = $null
if (@($descriptors | Where-Object { $_.provider -eq 'azure-devops' }).Count) { $azPath = Find-CommandPath @('az.cmd','az.exe','az') 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd' 'winget install --exact --id Microsoft.AzureCLI' }
if (@($descriptors | Where-Object { $_.provider -eq 'github' }).Count) { $ghPath = Find-CommandPath @('gh.exe','gh') '' 'winget install --exact --id GitHub.cli' }

if (-not $SkipAuthentication) {
    if ($azPath -and $AzureCredentialMode -eq 'azure-cli') {
        & $azPath account show --output none 2>$null
        if($LASTEXITCODE -ne 0){Invoke-External $azPath @('login','--allow-no-subscriptions')}
        & $azPath extension show --name azure-devops --output none 2>$null
        if($LASTEXITCODE -ne 0){Invoke-External $azPath @('extension','add','--name','azure-devops')}
    }
    if ($ghPath -and $GitHubCredentialMode -eq 'gh-cli') {
        foreach($hostName in @($descriptors | Where-Object {$_.provider -eq 'github'} | Select-Object -ExpandProperty host -Unique)) {
            & $ghPath auth status --hostname $hostName *> $null
            if($LASTEXITCODE -ne 0){Invoke-External $ghPath @('auth','login','--hostname',$hostName,'--web')}
        }
    }
    & $codexPath login status *> $null
    if($LASTEXITCODE -ne 0){Invoke-External $codexPath @('login')}
}

$targetSkill = Join-Path $InstallRoot 'azure-pr-review-monitor'
if(Test-Path $targetSkill){if(-not $Force){throw "Skill already exists at $targetSkill. Use -Force to replace it."};Move-Item $targetSkill "$targetSkill.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"}
New-Item -ItemType Directory -Force -Path $InstallRoot,$DataRoot,(Join-Path $DataRoot 'review-skills'),(Join-Path $DataRoot 'review-prompts')|Out-Null
Copy-Item -LiteralPath $sourceSkill -Destination $targetSkill -Recurse
$config = New-AgentDefaultConfig
$config.schedule.pollIntervalMinutes=$PollIntervalMinutes;$config.schedule.dailyTime=$DailyTime
Write-AgentConfig -Config $config -Path (Join-Path $DataRoot 'config.json')
$settings = Join-Path $targetSkill 'scripts\manage_agent_settings.ps1'
for($i=0;$i -lt $RepositoryUrl.Count;$i++){
    $descriptor=$descriptors[$i];$reviewerValue=if($Reviewer.Count -eq 1){$Reviewer[0]}else{$Reviewer[$i]}
    if($descriptor.provider -eq 'azure-devops'){
        & $settings -Action AddRepository -DataRoot $DataRoot -RepositoryUrl $RepositoryUrl[$i] -Reviewer $reviewerValue -IncludeAuthors $IncludeAuthors -ExcludeAuthors $ExcludeAuthors -CredentialProfileId 'azure-default' -CredentialMode $AzureCredentialMode -CredentialEnvironmentVariable $AzureTokenEnvironmentVariable -CliPath $azPath
    }else{
        & $settings -Action AddRepository -DataRoot $DataRoot -RepositoryUrl $RepositoryUrl[$i] -Reviewer $reviewerValue -IncludeAuthors $IncludeAuthors -ExcludeAuthors $ExcludeAuthors -CredentialProfileId 'github-default' -CredentialMode $GitHubCredentialMode -CredentialEnvironmentVariable $GitHubTokenEnvironmentVariable -CliPath $ghPath
    }
}
& $settings -Action Validate -DataRoot $DataRoot
if(-not $SkipScheduledTasks){& (Join-Path $targetSkill 'scripts\install_scheduled_tasks.ps1') -PollIntervalMinutes $PollIntervalMinutes -DailyTime $DailyTime}
Write-Host "Installed skill: $targetSkill"
Write-Host "Configuration: $(Join-Path $DataRoot 'config.json')"
Write-Host 'No credential values were written to the package or configuration.'
Write-Host "Dry run: & '$targetSkill\scripts\run_pr_review_monitor.ps1' -Mode Manual -DryRun"
