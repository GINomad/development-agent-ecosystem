[CmdletBinding()]
param([AllowNull()][AllowEmptyString()][string] $Diagnostic)
Set-StrictMode -Version Latest
$text = ([string]$Diagnostic).Trim()
$category = 'execution'
$message = $text
$code = ''
if ($text -and $text -notmatch '(?i)^execution retry limit reached after\s+\d+\s+identical failures:') {
    $eligible = $true
    if ($text.StartsWith('{') -or $text.StartsWith('[')) {
        $eligible = $false
        try {
            $event = $text | ConvertFrom-Json -ErrorAction Stop
            if ($event -is [pscustomobject] -and -not $event.PSObject.Properties['taskId']) {
                $type = if ($event.PSObject.Properties['type']) { [string]$event.type } else { '' }
                if ($type -in @('error','session.error','turn.failed') -or ($type -eq 'result' -and $event.PSObject.Properties['is_error'] -and [bool]$event.is_error)) {
                    $eligible = $true
                    $payload = if ($event.PSObject.Properties['error']) { $event.error } elseif ($event.PSObject.Properties['data']) { $event.data } else { $event }
                    $message = ''
                    foreach ($name in @('message','result','text')) { if ($payload.PSObject.Properties[$name]) { $message = [string]$payload.$name; break } }
                    if ($payload -is [string]) { $message = [string]$payload }
                    if ($payload.PSObject.Properties['code']) { $code = [string]$payload.code }
                }
            }
        } catch { }
    }
    if ($eligible) {
        # Match an actual failure assertion, never bare words from configuration or tool output.
        $limitPattern = '(?i)\b(?:rate[- ]?limit\s+(?:reached|exceeded)|too many requests|(?:exceeded|exhausted)\s+(?:your\s+)?(?:current\s+)?quota|quota(?:\s+limit)?\s+(?:reached|exceeded|exhausted)|insufficient[_ ]quota|(?:hit|reached|exceeded)\s+(?:your\s+)?usage limit|usage limit\s+(?:reached|exceeded)|individual spend limit\s+(?:reached|exceeded)|spend(?:ing)? limit\s+(?:reached|exceeded)|selected model is at capacity|model\s+(?:is\s+)?(?:overloaded|temporarily unavailable))\b'
        $authPattern = '(?i)\b(?:failed to authenticate|OAuth session expired|authentication failed|not logged in|unauthorized|invalid (?:api[- ]?key|authentication credentials)|access token (?:expired|revoked))\b'
        $transportPattern = '(?i)\b(?:stream connection failed|connection failed: error sending request|could not resolve host|temporary failure in name resolution|connection (?:reset|refused)|network is unreachable|TLS handshake (?:failed|timeout))\b'
        if ($code -in @('rate_limit_exceeded','insufficient_quota','usage_limit_reached','model_overloaded') -or $message -match $limitPattern) { $category = 'provider-limit' }
        elseif ($code -in @('invalid_api_key','authentication_error') -or $message -match $authPattern) { $category = 'provider-authentication' }
        elseif ($message -match $transportPattern) { $category = 'provider-transport' }
    }
}
[pscustomobject]@{ Category=$category; IsProviderLimit=($category -eq 'provider-limit'); IsExternal=($category -ne 'execution'); Message=$message }
