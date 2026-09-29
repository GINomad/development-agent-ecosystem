[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('codex','copilot','claude')][string] $Provider,
    [string] $DestinationRoot,
    [switch] $Preview,
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\agents.json'),
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'AgentEcosystem.psm1') -Force
$root=Get-EcosystemRoot
$config=Get-EcosystemConfig -ConfigPath $ConfigPath -CodexHome $CodexHome
if(-not $DestinationRoot){
    $DestinationRoot=switch($Provider){
        'codex'{Get-DefaultCodexHome -Override $CodexHome}
        'copilot'{Join-Path ([string]$env:USERPROFILE) '.copilot'}
        'claude'{Join-Path ([string]$env:USERPROFILE) '.claude'}
    }
}
$DestinationRoot=[IO.Path]::GetFullPath($DestinationRoot)
$written=[Collections.Generic.List[string]]::new()
$unchanged=[Collections.Generic.List[string]]::new()

function Write-ManagedText([string]$Path,[string]$Content){
    if(Test-Path -LiteralPath $Path -PathType Leaf){
        $current=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)
        if($current -eq $Content){$unchanged.Add($Path);return}
        throw "Refusing to overwrite a differing chat-only file: $Path"
    }
    if($Preview){$written.Add($Path);return}
    if($PSCmdlet.ShouldProcess($Path,'Install chat-only agent asset')){
        $parent=Split-Path -Parent $Path
        if(-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
        Write-Utf8NoBomAtomic -Path $Path -Content $Content
        $written.Add($Path)
    }
}
function Copy-ManagedTree([string]$Source,[string]$Destination){
    foreach($file in @(Get-ChildItem -LiteralPath $Source -Recurse -File)){
        if($file.Name -eq 'openai.yaml'){continue}
        $relative=$file.FullName.Substring(([IO.Path]::GetFullPath($Source).TrimEnd('\')+'\').Length)
        Write-ManagedText -Path (Join-Path $Destination $relative) -Content ([IO.File]::ReadAllText($file.FullName,[Text.Encoding]::UTF8))
    }
}

$portableSkills=@('apply-engineering-principles','develop-dotnet','develop-javascript-typescript','develop-react','verify-review-findings')
switch($Provider){
    'codex'{
        $agentRoot=Join-Path $DestinationRoot 'agents'
        foreach($agent in @($config.agents)){
            $target=Join-Path $agentRoot ($agent.name+'.toml')
            $content=New-AgentToml -Agent $agent -Config $config -CodexHome (Get-DefaultCodexHome -Override $CodexHome)
            Write-ManagedText -Path $target -Content $content
        }
        foreach($skill in $portableSkills){Copy-ManagedTree -Source (Join-Path $root ('plugins\development-agent-ecosystem\skills\'+$skill)) -Destination (Join-Path $DestinationRoot ('skills\'+$skill))}
    }
    'copilot'{
        Copy-ManagedTree -Source (Join-Path $root '.github\agents') -Destination (Join-Path $DestinationRoot 'agents')
        Copy-ManagedTree -Source (Join-Path $root '.github\skills') -Destination (Join-Path $DestinationRoot 'skills')
    }
    'claude'{
        $installerPath=Join-Path $root 'INSTALL-CLAUDE-VSCODE-AGENTS.md'
        $installer=[IO.File]::ReadAllText($installerPath,[Text.Encoding]::UTF8)
        $commonMatch=[regex]::Match($installer,'(?ms)^### 5\. Common standalone contract.*?^```markdown\r?\n(?<body>.*?)^```\s*$')
        if(-not $commonMatch.Success){throw 'Claude standalone common contract was not found.'}
        $agentMatches=[regex]::Matches($installer,'(?ms)^#### `(?<name>development-[^`]+\.md)`\s*\r?\n\r?\n```yaml\r?\n(?<yaml>.*?)^```.*?^Role-specific body:\s*\r?\n\r?\n```markdown\r?\n(?<body>.*?)^```\s*$')
        if($agentMatches.Count -ne 8){throw "Expected 8 Claude standalone agents, found $($agentMatches.Count)."}
        foreach($match in $agentMatches){
            $content="---`n"+$match.Groups['yaml'].Value.Trim()+"`n---`n`n"+$commonMatch.Groups['body'].Value.Trim()+"`n`n"+$match.Groups['body'].Value.Trim()+"`n"
            Write-ManagedText -Path (Join-Path $DestinationRoot ('agents\'+$match.Groups['name'].Value)) -Content $content
        }
        foreach($skill in $portableSkills){Copy-ManagedTree -Source (Join-Path $root ('plugins\development-agent-ecosystem\skills\'+$skill)) -Destination (Join-Path $DestinationRoot ('skills\'+$skill))}
    }
}
[pscustomobject]@{Provider=$Provider;DestinationRoot=$DestinationRoot;Preview=[bool]$Preview;Written=@($written);Unchanged=@($unchanged);DashboardInstalled=$false}
