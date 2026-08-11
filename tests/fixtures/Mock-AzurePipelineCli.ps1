Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$resourceIndex = [Array]::IndexOf([object[]]$args, '--resource')
$resource = if ($resourceIndex -ge 0) { [string]$args[$resourceIndex + 1] } else { '' }
$commit = [string]$env:ECOSYSTEM_MOCK_COMMIT
$scenario = [string]$env:ECOSYSTEM_MOCK_PIPELINE_SCENARIO

if ($scenario -eq 'ordered-success') {
    $statePath = [string]$env:ECOSYSTEM_MOCK_PIPELINE_STATE
    if ([string]::IsNullOrWhiteSpace($statePath)) { throw 'Ordered mock scenario requires ECOSYSTEM_MOCK_PIPELINE_STATE.' }
    if ($args[0] -eq 'pipelines' -and $args[1] -eq 'runs' -and $args[2] -eq 'list') {
        @([ordered]@{
            id = 9800
            sourceVersion = $commit
            queueTime = [DateTime]::UtcNow.ToString('o')
            definition = [ordered]@{ id=892; name='Earlier synthetic build' }
        }) | ConvertTo-Json -Depth 6 -Compress
        exit 0
    }
    if ($args[0] -eq 'pipelines' -and $args[1] -eq 'run') {
        $definitionIndex = [Array]::IndexOf([object[]]$args, '--id')
        $definitionId = [int]$args[$definitionIndex + 1]
        $actions = if (Test-Path -LiteralPath $statePath) { @(Get-Content -LiteralPath $statePath) } else { @() }
        if ($definitionId -eq 892 -and ($actions -join ',') -ne 'queued:814,succeeded:814') { throw 'Definition 892 was queued before definition 814 succeeded.' }
        Add-Content -LiteralPath $statePath -Value "queued:$definitionId" -Encoding UTF8
        [ordered]@{ id=if ($definitionId -eq 814) { 9814 } else { 9892 }; definition=[ordered]@{ id=$definitionId; name="Synthetic build $definitionId" } } | ConvertTo-Json -Depth 6 -Compress
        exit 0
    }
    if ($args[0] -eq 'pipelines' -and $args[1] -eq 'runs' -and $args[2] -eq 'show') {
        $runIdIndex = [Array]::IndexOf([object[]]$args, '--id')
        $runId = [int]$args[$runIdIndex + 1]
        $definitionId = if ($runId -eq 9814) { 814 } elseif ($runId -eq 9892) { 892 } else { throw "Unexpected ordered mock run ID: $runId" }
        Add-Content -LiteralPath $statePath -Value "succeeded:$definitionId" -Encoding UTF8
        [ordered]@{
            id = $runId
            status = 'completed'
            result = 'succeeded'
            sourceVersion = $commit
            definition = [ordered]@{ id=$definitionId; name="Synthetic build $definitionId" }
        } | ConvertTo-Json -Depth 6 -Compress
        exit 0
    }
    throw "Unexpected ordered mock Azure CLI arguments: $($args -join ' ')"
}

if ($scenario -eq 'latest-terminal') {
    if ($args[0] -eq 'pipelines' -and $args[1] -eq 'runs' -and $args[2] -eq 'list') {
        @(
            [ordered]@{ id=99001; sourceVersion=$commit; queueTime=[DateTime]::UtcNow.AddMinutes(-2).ToString('o'); definition=[ordered]@{ id=814; name='Older retry' } },
            [ordered]@{ id=99002; sourceVersion=$commit; queueTime=[DateTime]::UtcNow.AddMinutes(-1).ToString('o'); definition=[ordered]@{ id=814; name='Newest retry' } }
        ) | ConvertTo-Json -Depth 6 -Compress
        exit 0
    }
    if ($args[0] -eq 'pipelines' -and $args[1] -eq 'runs' -and $args[2] -eq 'show') {
        $runIdIndex = [Array]::IndexOf([object[]]$args, '--id')
        $runId = [int]$args[$runIdIndex + 1]
        if ($runId -ne 99002) { throw "Targeted refresh selected stale run $runId instead of newest run 99002." }
        [ordered]@{ id=99002; status='completed'; result='failed'; sourceVersion=$commit; definition=[ordered]@{ id=814; name='Newest retry' } } | ConvertTo-Json -Depth 6 -Compress
        exit 0
    }
}

if ($args[0] -eq 'pipelines' -and $args[1] -eq 'runs' -and $args[2] -eq 'list') {
    @([ordered]@{
        id = 99001
        sourceVersion = $commit
        queueTime = [DateTime]::UtcNow.ToString('o')
        definition = [ordered]@{ id=892; name='Synthetic build' }
    }) | ConvertTo-Json -Depth 6 -Compress
    exit 0
}
if ($args[0] -eq 'pipelines' -and $args[1] -eq 'runs' -and $args[2] -eq 'show') {
    [ordered]@{
        id = 99001
        status = 'completed'
        result = 'failed'
        sourceVersion = $commit
        definition = [ordered]@{ id=892; name='Synthetic build' }
    } | ConvertTo-Json -Depth 6 -Compress
    exit 0
}
if ($resource -eq 'timeline') {
    [ordered]@{ records=@([ordered]@{ type='Task'; result='failed'; name='Compile application'; log=[ordered]@{ id=7 } }) } | ConvertTo-Json -Depth 8 -Compress
    exit 0
}
if ($resource -eq 'logs') {
    $outputIndex = [Array]::IndexOf([object[]]$args, '--out-file')
    if ($outputIndex -lt 0) { throw 'Mock log request has no --out-file.' }
    [IO.File]::WriteAllText([string]$args[$outputIndex + 1], "Program.cs(12,5): error CS1002: ; expected$([Environment]::NewLine)", (New-Object Text.UTF8Encoding($false)))
    exit 0
}
throw "Unexpected mock Azure CLI arguments: $($args -join ' ')"
