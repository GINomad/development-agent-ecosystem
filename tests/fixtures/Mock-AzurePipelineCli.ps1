Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$resourceIndex = [Array]::IndexOf([object[]]$args, '--resource')
$resource = if ($resourceIndex -ge 0) { [string]$args[$resourceIndex + 1] } else { '' }
$commit = [string]$env:ECOSYSTEM_MOCK_COMMIT
$scenario = [string]$env:ECOSYSTEM_MOCK_PIPELINE_SCENARIO

if ($scenario -like 'recovery-*') {
    if ($args[0] -eq 'pipelines' -and $args[1] -eq 'run') {
        throw "Recovery scenario '$scenario' must never queue a pipeline."
    }
    if ($args[0] -eq 'pipelines' -and $args[1] -eq 'runs' -and $args[2] -eq 'list') {
        if ([Array]::IndexOf([object[]]$args, '--branch') -ge 0) {
            throw "Recovery scenario '$scenario' must discover configured passive definitions without a feature-branch filter."
        }
        $matchingParameters = ([ordered]@{ 'system.pullRequest.sourceCommitId'=$commit } | ConvertTo-Json -Compress)
        $mismatchedParameters = ([ordered]@{ 'system.pullRequest.sourceCommitId'='ffffffffffffffffffffffffffffffffffffffff' } | ConvertTo-Json -Compress)
        $runs = switch ($scenario) {
            'recovery-zero' { @() }
            'recovery-singleton-string' {
                [ordered]@{ id=9126; sourceVersion='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; parameters=$matchingParameters; queueTime=[DateTime]::UtcNow.ToString('o'); definition=[ordered]@{ id=17; name='PR validation' } }
            }
            'recovery-singleton-object' {
                [ordered]@{ id=9127; sourceVersion='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'; parameters=[ordered]@{ system=[ordered]@{ pullRequest=[ordered]@{ sourceCommitId=$commit } } }; queueTime=[DateTime]::UtcNow.ToString('o'); definition=[ordered]@{ id=17; name='PR validation object parameters' } }
            }
            'recovery-mismatch' {
                [ordered]@{ id=9128; sourceVersion='cccccccccccccccccccccccccccccccccccccccc'; parameters=$mismatchedParameters; queueTime=[DateTime]::UtcNow.ToString('o'); definition=[ordered]@{ id=17; name='Mismatched PR validation' } }
            }
            'recovery-multiple' {
                @(
                    [ordered]@{ id=9130; sourceVersion=$commit; queueTime=[DateTime]::UtcNow.AddSeconds(-5).ToString('o'); definition=[ordered]@{ id=17; name='Direct exact commit' } },
                    [ordered]@{ id=9131; sourceVersion='dddddddddddddddddddddddddddddddddddddddd'; parameters=$matchingParameters; queueTime=[DateTime]::UtcNow.AddSeconds(-4).ToString('o'); definition=[ordered]@{ id=17; name='Matching PR validation' } },
                    [ordered]@{ id=9132; sourceVersion='eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'; parameters=$mismatchedParameters; queueTime=[DateTime]::UtcNow.AddSeconds(-3).ToString('o'); definition=[ordered]@{ id=17; name='Mismatched PR validation' } },
                    [ordered]@{ id=9133; sourceVersion='1111111111111111111111111111111111111111'; parameters='{malformed'; queueTime=[DateTime]::UtcNow.AddSeconds(-2).ToString('o'); definition=[ordered]@{ id=17; name='Malformed PR parameters' } },
                    [ordered]@{ id=9134; sourceVersion='2222222222222222222222222222222222222222'; queueTime=[DateTime]::UtcNow.AddSeconds(-1).ToString('o'); definition=[ordered]@{ id=17; name='Absent PR parameters' } },
                    [ordered]@{ id=9135; sourceVersion=$commit; queueTime=[DateTime]::UtcNow.ToString('o'); definition=[ordered]@{ id=18; name='Unconfigured definition' } }
                )
            }
            default { throw "Unexpected recovery mock scenario: $scenario" }
        }
        ConvertTo-Json -InputObject $runs -Depth 10 -Compress
        exit 0
    }
    if ($args[0] -eq 'pipelines' -and $args[1] -eq 'runs' -and $args[2] -eq 'show') {
        $runIdIndex = [Array]::IndexOf([object[]]$args, '--id')
        $runId = [int]$args[$runIdIndex + 1]
        $sourceVersion = switch ($runId) {
            9126 { 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
            9127 { 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' }
            9130 { $commit }
            9131 { 'dddddddddddddddddddddddddddddddddddddddd' }
            default { throw "Recovery scenario '$scenario' selected unexpected run $runId." }
        }
        [ordered]@{ id=$runId; status='completed'; result='succeeded'; sourceVersion=$sourceVersion; definition=[ordered]@{ id=17; name='PR validation' } } | ConvertTo-Json -Depth 6 -Compress
        exit 0
    }
    throw "Unexpected recovery mock Azure CLI arguments: $($args -join ' ')"
}

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
