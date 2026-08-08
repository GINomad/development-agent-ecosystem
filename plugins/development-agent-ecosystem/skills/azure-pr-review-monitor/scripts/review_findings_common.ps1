function Get-MarkdownField {
    param([string] $Body, [string] $Name)
    $match = [regex]::Match($Body, "(?m)^\*\*$([regex]::Escape($Name)):\*\*\s*(?<value>.+?)\s*$")
    if ($match.Success) { return $match.Groups["value"].Value.Trim().Trim('`') }
    return ""
}

function ConvertTo-ReviewRule {
    param([string] $Value)
    $normalized = $Value.ToLowerInvariant() -replace '[^a-z0-9]+', '_'
    return $normalized.Trim('_')
}

function Get-ReviewFindingId {
    param([string] $Rule, [string] $File)
    $inputValue = "$(ConvertTo-ReviewRule $Rule)|$($File.Replace('\','/').ToLowerInvariant())"
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($inputValue)) } finally { $sha.Dispose() }
    $hex = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    return "RVW-$($hex.Substring(0, 12).ToUpperInvariant())"
}

function Get-ReviewFindings {
    param([Parameter(Mandatory)][string] $ReviewContent)
    $results = [Collections.Generic.List[object]]::new()
    $matches = [regex]::Matches($ReviewContent, '(?ms)^### \[?(?<severity>HIGH|MEDIUM|LOW)\]? (?<title>[^\r\n]+)\r?\n(?<body>.*?)(?=^### \[?(?:HIGH|MEDIUM|LOW)\]? |^## |\z)')
    foreach ($match in $matches) {
        $body = $match.Groups['body'].Value.Trim()
        $location = Get-MarkdownField $body 'Location'
        $locationMatch = [regex]::Match($location, '^(?<file>.+?):(?<line>\d+)$')
        $file = if ($locationMatch.Success) { $locationMatch.Groups['file'].Value.Replace('\','/') } else { '' }
        $line = if ($locationMatch.Success) { [int]$locationMatch.Groups['line'].Value } else { 0 }
        $title = $match.Groups['title'].Value.Trim()
        $rule = Get-MarkdownField $body 'Rule'
        if ([string]::IsNullOrWhiteSpace($rule)) { $rule = ConvertTo-ReviewRule $title }
        $rule = ConvertTo-ReviewRule $rule
        $results.Add([pscustomobject][ordered]@{
            FindingId = Get-ReviewFindingId $rule $file
            Rule = $rule
            Severity = $match.Groups['severity'].Value
            Title = $title
            File = $file
            Line = $line
            Comment = Get-MarkdownField $body 'Comment'
            Why = Get-MarkdownField $body 'Why it matters'
            Recommendation = Get-MarkdownField $body 'Recommendation'
            Disposition = 'actionable'
            DispositionReason = ''
        })
    }
    return @($results)
}

function Read-ReviewDispositions {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $document = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    return @($document.items)
}

function Get-ReviewDisposition {
    param(
        [Parameter(Mandatory)] $Finding,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Dispositions,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][int] $PullRequestId
    )
    $now = (Get-Date).ToUniversalTime()
    $matches = @($Dispositions | Where-Object {
        $item = $_
        if ($item.expiresAt) {
            $expiry = [DateTime]::MinValue
            if ([DateTime]::TryParse([string]$item.expiresAt, [ref]$expiry) -and $expiry.ToUniversalTime() -lt $now) { return $false }
        }
        if (-not [string]::Equals([string]$item.repository, $Repository, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if ([string]$item.scope -eq 'pull-request' -and [int]$item.pullRequestId -ne $PullRequestId) { return $false }
        $exact = [string]::Equals([string]$item.findingId, [string]$Finding.FindingId, [StringComparison]::OrdinalIgnoreCase)
        $ruleAndPath = [string]::Equals([string]$item.rule, [string]$Finding.Rule, [StringComparison]::OrdinalIgnoreCase) -and ([string]$Finding.File -like [string]$item.filePattern)
        return $exact -or $ruleAndPath
    } | Sort-Object createdAt -Descending)
    return $matches | Select-Object -First 1
}

function Write-ReviewDispositions {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Items)
    $document = [ordered]@{ version = 1; updatedAtUtc = (Get-Date).ToUniversalTime().ToString('o'); items = @($Items) }
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporary = "$Path.tmp"
    $document | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

