Set-StrictMode -Version Latest
function Read-McpBoundSnapshot {
    param([Parameter(Mandatory)][string] $Path,[string] $ExpectedSha256,[string] $Label='Bound file',[scriptblock] $AfterReadAction)
    $bytes=[IO.File]::ReadAllBytes($Path)
    if($AfterReadAction){& $AfterReadAction}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$actual=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    if($ExpectedSha256 -and $actual -ne $ExpectedSha256.ToLowerInvariant()){throw "$Label revision changed after the MCP session was issued."}
    [pscustomobject]@{Path=[IO.Path]::GetFullPath($Path);Bytes=$bytes;Sha256=$actual;Text=[Text.Encoding]::UTF8.GetString($bytes)}
}
