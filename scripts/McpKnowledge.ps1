function Get-McpKnowledgeResult {
    param($Session,[string]$Tool,$Arguments)
    if(-not $Session.PSObject.Properties['knowledgeManifestPath'] -or -not $Session.knowledgeManifestPath){throw 'No knowledge snapshot is bound to this session.'}
    $manifestPath=[IO.Path]::GetFullPath([string]$Session.knowledgeManifestPath)
    $taskPrefix=[IO.Path]::GetFullPath([string]$Session.taskRoot).TrimEnd('\')+'\'
    if(-not $manifestPath.StartsWith($taskPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Knowledge manifest escapes task root.'}
    $snapshotRoot=Split-Path -Parent $manifestPath
    function Assert-KnowledgePath([string]$Path) {
        $resolved=[IO.Path]::GetFullPath($Path)
        if(-not $resolved.StartsWith($snapshotRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Knowledge path escapes snapshot.'}
        $current=$resolved
        while($current -and $current.StartsWith($taskPrefix,[StringComparison]::OrdinalIgnoreCase)){
            if((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked knowledge paths are forbidden.'}
            $current=Split-Path -Parent $current
        }
    }
    Assert-KnowledgePath $manifestPath
    if((FileSha $manifestPath) -ne [string]$Session.knowledgeManifestSha256){throw 'Knowledge manifest integrity validation failed.'}
    $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    $name=if($Arguments -and $Arguments.PSObject.Properties['name']){[string]$Arguments.name}else{''}
    $offset=if($Arguments -and $Arguments.PSObject.Properties['offset']){[int]$Arguments.offset}else{0}
    if($offset -lt 0){throw 'Offset must not be negative.'}
    if($Tool -eq 'list_knowledge'){
        $entries=@($manifest.entries|Where-Object{-not $name -or ([string]$_.relativePath).IndexOf($name,[StringComparison]::OrdinalIgnoreCase) -ge 0})
        $items=@($entries|Select-Object -Skip $offset -First 40|ForEach-Object{@{name=$_.relativePath;revision=$_.sha256}})
        return @{source='shared-knowledge.json';revision=$Session.knowledgeManifestSha256;retrievedAtUtc=[DateTime]::UtcNow.ToString('o');truncated=($offset+$items.Count -lt $entries.Count);data=@{projectId=$manifest.projectId;total=$entries.Count;offset=$offset;items=$items}}
    }
    $entry=@($manifest.entries|Where-Object{[string]$_.relativePath -ceq $name}|Select-Object -First 1)
    if($entry.Count -ne 1){throw 'Knowledge entry is not in this task snapshot.'}
    $path=[IO.Path]::GetFullPath([string]$entry[0].snapshotPath)
    Assert-KnowledgePath $path
    $revision=FileSha $path
    if($revision -ne [string]$entry[0].sha256){throw 'Knowledge file integrity validation failed.'}
    if([IO.Path]::GetExtension($path).ToLowerInvariant() -notin @('.md','.txt','.json','.yaml','.yml','.ps1','.html','.csv')){throw 'Binary knowledge is indexed; use its local snapshot file with a suitable viewer.'}
    $raw=Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if($null -eq $raw){$raw=''}
    if($offset -gt $raw.Length){throw 'Offset exceeds knowledge length.'}
    $excerpt=$raw.Substring($offset,[Math]::Min(12000,$raw.Length-$offset))
    return @{source=$name;revision=$revision;retrievedAtUtc=[DateTime]::UtcNow.ToString('o');truncated=($offset+$excerpt.Length -lt $raw.Length);data=@{projectId=$manifest.projectId;sourcePath=$entry[0].sourcePath;offset=$offset;totalCharacters=$raw.Length;excerpt=$excerpt}}
}
