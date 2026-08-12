[CmdletBinding()]
param(
    [string[]] $TaskNames = @(),
    [string[]] $LogLines = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$text = (@($TaskNames) + @($LogLines) -join [Environment]::NewLine)
$signals = [Collections.Generic.List[string]]::new()

$patterns = [ordered]@{
    test = @(
        '(?im)\b(test run failed|tests? failed|failed tests?|assert(?:ion)? failed|xunit|nunit|jest|vitest|mocha|karma)\b',
        '(?im)\b(expected|actual)\s*:',
        '(?im)\b(failed|failure)\b.*\b(test|spec)\b'
    )
    code = @(
        '(?im)\berror\s+CS\d{4}\b',
        '(?im)\berror\s+TS\d{4}\b',
        '(?im)\b(compilation|compile|typescript compilation)\s+failed\b',
        '(?im)\b(syntaxerror|typeerror|referenceerror)\b',
        '(?im)\beslint\b.*\berror\b',
        '(?im)\bbuild failed\b.*\b(error|compil)'
        '(?im)\b(yaml|yml|azure-pipelines?)\b.*\b(invalid|syntax|parse|mapping|configuration error)\b',
        '(?im)\b(unexpected value|unexpected property|did not find expected key)\b',
        '(?im)Excel deliverable validation failed with exit code\s*\.(?:\s|$)'
    )
    infrastructure = @(
        '(?im)\b(0x)?800B010A\b|\bCERT_E_CHAINING\b|\bcertificate chain\b.*\b(cannot|could not|failed|unable|untrusted|trusted root)\b',
        '(?im)\b(unauthorized|forbidden|authentication failed|service connection)\b',
        '(?im)\b(agent|runner)\b.*\b(offline|unavailable|lost|not found)\b',
        '(?im)\b(timed? out|timeout|econnreset|enotfound|network error|connection refused)\b',
        '(?im)\b(registry|docker login|azure cli)\b.*\b(failed|error|denied)\b',
        '(?im)\b(unable to load the service index|rate limit|quota exceeded)\b'
    )
}

$category = 'unknown'
foreach ($candidate in @('test','code','infrastructure')) {
    foreach ($pattern in $patterns[$candidate]) {
        $match = [regex]::Match($text, $pattern)
        if (-not $match.Success) { continue }
        if ($category -eq 'unknown') { $category = $candidate }
        if ($signals.Count -lt 8) { $signals.Add($match.Value.Trim()) }
    }
    if ($category -ne 'unknown') { break }
}

[pscustomobject][ordered]@{
    category = $category
    developerEligible = $category -in @('code','test')
    matchedSignals = @($signals)
}
