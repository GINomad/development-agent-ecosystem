[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SourceRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]*$')][string] $ProjectId,
    [Parameter(Mandatory)][string] $OutputRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$source=(Resolve-Path -LiteralPath $SourceRoot).Path
$output=[IO.Path]::GetFullPath($OutputRoot)
$sourcePrefix=$source.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
if ($output.Equals($source,[StringComparison]::OrdinalIgnoreCase) -or $output.StartsWith($sourcePrefix,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Knowledge snapshots must be outside the source knowledge root.'
}
$selected=@('global',"projects/$ProjectId")
$files=[Collections.Generic.List[object]]::new()
foreach($relativeRoot in $selected) {
    $root=Join-Path $source $relativeRoot
    if(-not (Test-Path -LiteralPath $root -PathType Container)){throw "Knowledge source is missing: $root"}
    # Do not traverse linked directories outside the selected knowledge scope.
    $pending=[Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($root)
    while($pending.Count) {
        $directory=$pending.Dequeue()
        $item=Get-Item -LiteralPath $directory
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Linked knowledge directory is not supported: $directory"}
        foreach($entry in @(Get-ChildItem -LiteralPath $directory -Force)) {
            if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Linked knowledge entry is not supported: $($entry.FullName)"}
            if($entry.PSIsContainer){if($entry.Name -ne '.git'){$pending.Enqueue($entry.FullName)};continue}
            $files.Add($entry)
        }
    }
}
$snapshot=Join-Path $output ([guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $snapshot -Force
$entries=[Collections.Generic.List[object]]::new()
foreach($file in @($files|Sort-Object FullName)) {
    $relative=[IO.Path]::GetRelativePath($source,$file.FullName)
    $target=Join-Path $snapshot $relative
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
    $before=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    Copy-Item -LiteralPath $file.FullName -Destination $target
    $copied=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    $after=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    if($before -ne $copied -or $after -ne $copied){throw "Knowledge changed while copying; retry the snapshot: $relative"}
    $entries.Add([ordered]@{relativePath=$relative.Replace('\','/');sourcePath=$file.FullName;snapshotPath=$target;sha256=$copied})
}
$manifest=Join-Path $snapshot 'shared-knowledge.json'
$document=[ordered]@{projectId=$ProjectId;sourceRoot=$source;createdAtUtc=[DateTime]::UtcNow.ToString('o');access='read-only-reference';includesUncommittedFiles=$true;entries=@($entries)}
[IO.File]::WriteAllText($manifest,($document|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
[pscustomobject]@{Root=$snapshot;ManifestPath=$manifest;GlobalRoot=(Join-Path $snapshot 'global');ProjectRoot=(Join-Path $snapshot "projects/$ProjectId");FileCount=$entries.Count}
