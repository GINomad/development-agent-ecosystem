[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $DiffPath,
    [Parameter(Mandatory)][string] $ReviewPath,
    [Parameter(Mandatory)][string] $OutputPath,
    [Parameter(Mandatory)][string] $Title,
    [ValidateRange(1024, 65535)][int] $DashboardPort = 47831
)

$ErrorActionPreference = 'Stop'
function Encode-Html { param([AllowEmptyString()][string] $Value) [Net.WebUtility]::HtmlEncode($Value) }
function Get-Field {
    param([string] $Body, [string] $Name)
    $match = [regex]::Match($Body, "(?m)^\*\*$([regex]::Escape($Name)):\*\*\s*(?<value>.+)$")
    if ($match.Success) { return $match.Groups['value'].Value.Trim().Trim('`') }
    return ''
}
function New-FindingView {
    param($Source)
    return [pscustomobject]@{
        Severity = [string]$Source.Severity
        Title = [string]$Source.Title
        FindingId = [string]$Source.FindingId
        Rule = [string]$Source.Rule
        File = ([string]$Source.File).Replace('\', '/')
        Line = [int]$Source.Line
        Comment = [string]$Source.Comment
        Why = [string]$Source.Why
        Recommendation = [string]$Source.Recommendation
        Disposition = $(if ($Source.Disposition) { [string]$Source.Disposition } else { 'actionable' })
        DispositionReason = [string]$Source.DispositionReason
        Placed = $false
    }
}

$utf8 = New-Object Text.UTF8Encoding($false)
$review = [IO.File]::ReadAllText($ReviewPath, $utf8)
$diffLines = [IO.File]::ReadAllLines($DiffPath, $utf8)
$findings = [Collections.Generic.List[object]]::new()
$sidecarPath = [IO.Path]::ChangeExtension($ReviewPath, '.findings.json')
if (Test-Path -LiteralPath $sidecarPath) {
    $sidecar = [IO.File]::ReadAllText($sidecarPath, $utf8) | ConvertFrom-Json
    foreach ($item in @($sidecar.findings)) { $findings.Add((New-FindingView $item)) }
}
else {
    $matches = [regex]::Matches($review, '(?ms)^### \[?(?<severity>HIGH|MEDIUM|LOW)\]? (?<title>[^\r\n]+)\r?\n(?<body>.*?)(?=^### \[?(?:HIGH|MEDIUM|LOW)\]? |^## |\z)')
    foreach ($match in $matches) {
        $body = $match.Groups['body'].Value.Trim()
        $location = Get-Field $body 'Location'
        $locationMatch = [regex]::Match($location, '^(?<file>.+?):(?<line>\d+)$')
        $findings.Add((New-FindingView ([pscustomobject]@{
            Severity = $match.Groups['severity'].Value
            Title = $match.Groups['title'].Value.Trim()
            FindingId = Get-Field $body 'Finding ID'
            Rule = Get-Field $body 'Rule'
            File = $(if ($locationMatch.Success) { $locationMatch.Groups['file'].Value } else { '' })
            Line = $(if ($locationMatch.Success) { [int]$locationMatch.Groups['line'].Value } else { 0 })
            Comment = Get-Field $body 'Comment'
            Why = Get-Field $body 'Why it matters'
            Recommendation = Get-Field $body 'Recommendation'
            Disposition = 'actionable'
            DispositionReason = ''
        })))
    }
}

$files = [Collections.Generic.List[object]]::new()
$currentFile = $null
$oldLine = 0
$newLine = 0
foreach ($text in $diffLines) {
    $fileMatch = [regex]::Match($text, '^diff --git a/(?<old>.+) b/(?<new>.+)$')
    if ($fileMatch.Success) {
        $currentFile = [pscustomobject]@{ Path = $fileMatch.Groups['new'].Value.Trim('"').Replace('\', '/'); Lines = [Collections.Generic.List[object]]::new() }
        $files.Add($currentFile)
        continue
    }
    if (-not $currentFile) { continue }
    $hunk = [regex]::Match($text, '^@@ -(?<old>\d+)(?:,\d+)? \+(?<new>\d+)(?:,\d+)? @@')
    if ($hunk.Success) {
        $oldLine = [int]$hunk.Groups['old'].Value
        $newLine = [int]$hunk.Groups['new'].Value
        $currentFile.Lines.Add([pscustomobject]@{ Kind = 'hunk'; Old = 0; New = 0; Text = $text })
        continue
    }
    if ($text -match '^(\+\+\+ |--- |index |new file |deleted file |similarity index |rename from |rename to )') { continue }
    if ($text.StartsWith('+')) { $currentFile.Lines.Add([pscustomobject]@{ Kind = 'added'; Old = 0; New = $newLine; Text = $text.Substring(1) }); $newLine++ }
    elseif ($text.StartsWith('-')) { $currentFile.Lines.Add([pscustomobject]@{ Kind = 'removed'; Old = $oldLine; New = 0; Text = $text.Substring(1) }); $oldLine++ }
    elseif ($text.StartsWith(' ')) { $currentFile.Lines.Add([pscustomobject]@{ Kind = 'context'; Old = $oldLine; New = $newLine; Text = $text.Substring(1) }); $oldLine++; $newLine++ }
    else { $currentFile.Lines.Add([pscustomobject]@{ Kind = 'meta'; Old = 0; New = 0; Text = $text }) }
}

$html = New-Object Text.StringBuilder
$changeIndex = 0
function Add-FindingBox {
    param($Finding, [switch]$ShowLocation)
    $severity = $Finding.Severity.ToLowerInvariant()
    $disposition = if ($Finding.Disposition) { $Finding.Disposition } else { 'actionable' }
    $id = Encode-Html $Finding.FindingId
    [void]$html.AppendLine("<div class='comment-box $severity disposition-$disposition' id='finding-$id' data-finding-id='$id' data-disposition='$(Encode-Html $disposition)'>")
    [void]$html.AppendLine("<div class='comment-title'><span class='badge'>$(Encode-Html $Finding.Severity)</span><code>$id</code> $(Encode-Html $Finding.Title)</div>")
    if ($ShowLocation) { [void]$html.AppendLine("<div class='comment-row'><b>Location</b> $(Encode-Html ($Finding.File + ':' + $Finding.Line))</div>") }
    if ($Finding.Comment) { [void]$html.AppendLine("<div class='comment-row'><b>Comment</b> $(Encode-Html $Finding.Comment)</div>") }
    if ($Finding.Why) { [void]$html.AppendLine("<div class='comment-row'><b>Why it matters</b> $(Encode-Html $Finding.Why)</div>") }
    if ($Finding.Recommendation) { [void]$html.AppendLine("<div class='comment-row'><b>Recommendation</b> $(Encode-Html $Finding.Recommendation)</div>") }
    [void]$html.AppendLine("<div class='finding-state'><span class='state-label'>$(Encode-Html $disposition)</span><span class='state-reason'>$(Encode-Html $Finding.DispositionReason)</span></div>")
    [void]$html.AppendLine("<div class='finding-actions'><button type='button' data-action='bypass'>Bypass</button><button type='button' data-action='falsePositive'>False positive</button><button type='button' data-action='restore'>Restore</button><button type='button' class='publish' data-action='publish'>Publish to PR</button></div>")
    [void]$html.AppendLine('</div>')
}

$htmlName = [IO.Path]::GetFileName($OutputPath)
$reviewName = [IO.Path]::GetFileName($ReviewPath)
$dashboardUrl = "http://127.0.0.1:$DashboardPort/review/$([Uri]::EscapeDataString($htmlName))"
[void]$html.AppendLine('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">')
[void]$html.AppendLine("<title>$(Encode-Html $Title)</title>")
[void]$html.AppendLine(@'
<style>
:root{font-family:"Segoe UI",Arial,sans-serif;color:#242424;background:#f5f5f5;font-size:14px}*{box-sizing:border-box}body{margin:0}.top{min-height:52px;background:#fff;border-bottom:1px solid #ddd;display:flex;gap:16px;align-items:center;padding:8px 24px;position:sticky;top:0;z-index:5}.top h1{font-size:18px;font-weight:600;margin:0;flex:1}.dashboard-link{color:#005a9e;text-decoration:none;font-weight:600}.layout{display:grid;grid-template-columns:260px minmax(0,1fr);min-height:calc(100vh - 52px)}nav{background:#fff;border-right:1px solid #ddd;padding:18px 12px;position:sticky;top:52px;height:calc(100vh - 52px);overflow:auto}nav h2{font-size:13px;margin:0 8px 12px;color:#616161;text-transform:uppercase}nav a{display:block;padding:7px 8px;color:#005a9e;text-decoration:none;overflow-wrap:anywhere}nav a:hover{background:#eff6fc}main{padding:20px;min-width:0}.mode-banner{border:1px solid #8ab4d8;background:#eff6fc;padding:11px 14px;margin-bottom:14px}.mode-banner.interactive{border-color:#8ec5a4;background:#effaf3}.summary,.file,.unplaced{background:#fff;border:1px solid #d6d6d6;margin-bottom:18px}.summary,.unplaced{padding:16px}.summary h2,.unplaced h2{font-size:17px;margin:0 0 12px}.summary pre{white-space:pre-wrap;font:13px/1.5 "Cascadia Mono",Consolas,monospace;margin:0}.file h2{font-size:14px;margin:0;padding:11px 14px;border-bottom:1px solid #ddd;overflow-wrap:anywhere}.diff{width:100%;border-collapse:collapse;table-layout:fixed;font:12px/1.5 "Cascadia Mono",Consolas,monospace}.diff td{border-bottom:1px solid #eee;vertical-align:top}.ln{width:54px;text-align:right;padding:0 8px;color:#777;background:#fafafa;user-select:none}.code{padding:0 10px;white-space:pre-wrap;overflow-wrap:anywhere}.added .code{background:#e6ffec}.removed .code{background:#ffebe9}.hunk td{padding:5px 10px;background:#eff6fc;color:#005a9e}.meta td{padding:3px 10px;color:#777}.comment td{padding:10px 14px 12px 118px;background:#fff}.comment-box{font:14px/1.45 "Segoe UI",Arial,sans-serif;border-left:4px solid #0078d4;background:#f3f9fd;padding:10px 12px;max-width:960px}.comment-box.high{border-color:#d13438;background:#fff4f4}.comment-box.medium{border-color:#ca5010;background:#fff8f0}.comment-box.disposition-bypass,.comment-box.disposition-false-positive{opacity:.74;border-color:#777;background:#f7f7f7}.comment-title{font-weight:600;margin-bottom:6px}.badge{display:inline-block;font-size:11px;font-weight:700;padding:2px 6px;margin-right:7px;background:#e5e5e5}.comment-row{margin-top:5px}.comment-row b{display:inline-block;min-width:112px}.finding-state{display:flex;gap:8px;align-items:center;margin-top:10px;color:#616161}.state-label{font-size:11px;font-weight:700;text-transform:uppercase;background:#e5e5e5;padding:3px 6px}.finding-actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}.finding-actions button,.dialog-actions button{border:1px solid #8a8886;background:#fff;padding:6px 10px;cursor:pointer}.finding-actions button:hover,.dialog-actions button:hover{background:#f3f2f1}.finding-actions .publish,.dialog-actions .primary{background:#0078d4;border-color:#0078d4;color:#fff}.finding-actions [data-action=restore]{display:none}.comment-box:not(.disposition-actionable) [data-action=bypass],.comment-box:not(.disposition-actionable) [data-action=falsePositive],.comment-box:not(.disposition-actionable) [data-action=publish]{display:none}.comment-box:not(.disposition-actionable) [data-action=restore]{display:inline-block}.unplaced .comment-box{margin:10px 0}.modal[hidden]{display:none}.modal{position:fixed;inset:0;background:rgba(0,0,0,.35);z-index:20;display:grid;place-items:center;padding:20px}.dialog{background:#fff;border:1px solid #777;width:min(520px,100%);padding:18px}.dialog h2{font-size:18px;margin:0 0 14px}.field{margin:12px 0}.field label{display:block;font-weight:600;margin-bottom:5px}.field input,.field select{width:100%;padding:7px;border:1px solid #8a8886}.dialog-actions{display:flex;justify-content:flex-end;gap:8px;margin-top:16px}.toast{position:fixed;right:18px;bottom:18px;max-width:480px;background:#242424;color:#fff;padding:11px 14px;z-index:30}.toast.error{background:#a4262c}.toast[hidden]{display:none}@media(max-width:900px){.layout{display:block}nav{position:static;height:auto;border-right:0;border-bottom:1px solid #ddd}.comment td{padding-left:14px}.top{position:static;flex-wrap:wrap}}
.change-nav{display:flex;align-items:center;gap:6px}.change-nav button{width:32px;height:32px;border:1px solid #8a8886;background:#fff;font-size:18px;cursor:pointer}.change-nav button:disabled{opacity:.45;cursor:default}.change-count{min-width:58px;text-align:center;color:#616161}.hunk.current-change td{background:#cfe8ff;box-shadow:inset 4px 0 #0078d4}
</style>
'@)
[void]$html.AppendLine('</head>')
[void]$html.AppendLine("<body data-review='$(Encode-Html $reviewName)' data-dashboard-url='$(Encode-Html $dashboardUrl)' data-csrf='__CODEX_REVIEW_CSRF__'>")
[void]$html.AppendLine("<header class='top'><h1>$(Encode-Html $Title)</h1><div class='change-nav'><button type='button' id='prev-change' title='Previous change' aria-label='Previous change'>&larr;</button><span class='change-count' id='change-count'>0 / 0</span><button type='button' id='next-change' title='Next change' aria-label='Next change'>&rarr;</button></div><a class='dashboard-link' href='$(Encode-Html $dashboardUrl)'>Interactive review</a></header><div class='layout'><nav><h2>Changed files</h2>")
for ($i = 0; $i -lt $files.Count; $i++) { [void]$html.AppendLine("<a href='#file-$i'>$(Encode-Html $files[$i].Path)</a>") }
[void]$html.AppendLine('</nav><main>')
[void]$html.AppendLine("<div class='mode-banner' id='mode-banner'>Opening interactive controls...</div>")
[void]$html.AppendLine("<section class='summary'><h2>Review summary</h2><pre>$(Encode-Html $review)</pre></section>")

for ($i = 0; $i -lt $files.Count; $i++) {
    $file = $files[$i]
    [void]$html.AppendLine("<section class='file' id='file-$i'><h2>$(Encode-Html $file.Path)</h2><table class='diff'><tbody>")
    foreach ($line in $file.Lines) {
        if ($line.Kind -eq 'hunk') { [void]$html.AppendLine("<tr class='hunk change-anchor' id='change-$changeIndex' data-change-index='$changeIndex'><td colspan='3'>$(Encode-Html $line.Text)</td></tr>"); $changeIndex++; continue }
        if ($line.Kind -eq 'meta') { [void]$html.AppendLine("<tr class='meta'><td colspan='3'>$(Encode-Html $line.Text)</td></tr>"); continue }
        $oldText = if ($line.Old) { [string]$line.Old } else { '' }
        $newText = if ($line.New) { [string]$line.New } else { '' }
        [void]$html.AppendLine("<tr class='$($line.Kind)'><td class='ln'>$(Encode-Html $oldText)</td><td class='ln'>$(Encode-Html $newText)</td><td class='code'>$(Encode-Html $line.Text)</td></tr>")
        if ($line.New) {
            $attached = @($findings | Where-Object { $_.Line -eq $line.New -and ($file.Path.Equals($_.File, [StringComparison]::OrdinalIgnoreCase) -or $file.Path.EndsWith("/$($_.File)", [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($file.Path).Equals([IO.Path]::GetFileName($_.File), [StringComparison]::OrdinalIgnoreCase)) })
            foreach ($finding in $attached) {
                $finding.Placed = $true
                [void]$html.AppendLine("<tr class='comment'><td colspan='3'>")
                Add-FindingBox $finding
                [void]$html.AppendLine('</td></tr>')
            }
        }
    }
    [void]$html.AppendLine('</tbody></table></section>')
}
$unplaced = @($findings | Where-Object { -not $_.Placed })
if ($unplaced.Count) {
    [void]$html.AppendLine("<section class='unplaced'><h2>Unplaced findings</h2>")
    foreach ($finding in $unplaced) { Add-FindingBox $finding -ShowLocation }
    [void]$html.AppendLine('</section>')
}
[void]$html.AppendLine(@'
<div class="modal" id="action-modal" hidden><div class="dialog" role="dialog" aria-modal="true" aria-labelledby="dialog-title">
<h2 id="dialog-title">Finding action</h2><div id="dialog-description"></div>
<div class="field" id="reason-field"><label for="reason">Reason</label><input id="reason" autocomplete="off"></div>
<div class="field" id="scope-field"><label for="scope">Scope</label><select id="scope"><option value="pull-request">This pull request</option><option value="repository">Repository and future PRs</option></select></div>
<div class="field" id="expires-field"><label for="expires">Expiration date (optional)</label><input id="expires" type="date"></div>
<div class="field" id="confirmation-field"><label for="confirmation">Type the finding ID to publish</label><input id="confirmation" autocomplete="off"></div>
<div class="dialog-actions"><button type="button" id="cancel-action">Cancel</button><button type="button" class="primary" id="apply-action">Apply</button></div>
</div></div><div class="toast" id="toast" hidden></div>
<script>
(() => {
  const body = document.body;
  const interactive = location.protocol === 'http:' && (location.hostname === '127.0.0.1' || location.hostname === 'localhost');
  const review = body.dataset.review;
  const dashboardUrl = body.dataset.dashboardUrl;
  const token = body.dataset.csrf;
  const banner = document.getElementById('mode-banner');
  banner.textContent = interactive ? 'Interactive mode: decisions are stored locally; Publish to PR creates one real provider comment after ID confirmation.' : 'Read-only file view. Use Interactive review or any action button to open working controls.';
  if (interactive) banner.classList.add('interactive');
  const modal = document.getElementById('action-modal');
  const reasonField = document.getElementById('reason-field');
  const scopeField = document.getElementById('scope-field');
  const expiresField = document.getElementById('expires-field');
  const confirmationField = document.getElementById('confirmation-field');
  const reason = document.getElementById('reason');
  const scope = document.getElementById('scope');
  const expires = document.getElementById('expires');
  const confirmation = document.getElementById('confirmation');
  const applyButton = document.getElementById('apply-action');
  let current = null;
  const changes = [...document.querySelectorAll('.change-anchor')];
  const changeCount = document.getElementById('change-count');
  const previousChange = document.getElementById('prev-change');
  const nextChange = document.getElementById('next-change');
  let currentChange = -1;
  function jumpToChange(index) {
    if (!changes.length) return;
    currentChange = Math.max(0, Math.min(index, changes.length - 1));
    changes.forEach(change => change.classList.remove('current-change'));
    changes[currentChange].classList.add('current-change');
    changes[currentChange].scrollIntoView({ behavior: 'smooth', block: 'center' });
    changeCount.textContent = `${currentChange + 1} / ${changes.length}`;
    previousChange.disabled = currentChange === 0;
    nextChange.disabled = currentChange === changes.length - 1;
  }
  changeCount.textContent = `0 / ${changes.length}`;
  previousChange.disabled = !changes.length;
  nextChange.disabled = !changes.length;
  previousChange.addEventListener('click', () => jumpToChange(currentChange < 0 ? 0 : currentChange - 1));
  nextChange.addEventListener('click', () => jumpToChange(currentChange + 1));
  document.addEventListener('keydown', event => {
    if (event.target.matches('input,select,textarea')) return;
    if (event.key === '[') jumpToChange(currentChange < 0 ? 0 : currentChange - 1);
    if (event.key === ']') jumpToChange(currentChange + 1);
  });
  function showToast(message, error = false) { const toast = document.getElementById('toast'); toast.textContent = message; toast.className = error ? 'toast error' : 'toast'; toast.hidden = false; setTimeout(() => toast.hidden = true, 6000); }
  function applyState(finding) {
    if (!finding) return;
    const box = document.querySelector(`[data-finding-id="${CSS.escape(finding.FindingId)}"]`);
    if (!box) return;
    const disposition = finding.Disposition || 'actionable';
    box.className = box.className.replace(/disposition-[^\s]+/g, '').trim() + ` disposition-${disposition}`;
    box.dataset.disposition = disposition;
    box.querySelector('.state-label').textContent = disposition;
    box.querySelector('.state-reason').textContent = finding.DispositionReason || '';
  }
  async function sendAction(payload) {
    const response = await fetch('/api/action', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Codex-Review-Token': token }, body: JSON.stringify({ review, ...payload }) });
    const result = await response.json();
    if (!response.ok || !result.ok) throw new Error(result.error || 'Action failed.');
    applyState(result.finding);
    showToast(result.message || 'Action completed.');
  }
  function closeDialog() {
    modal.hidden = true;
    modal.setAttribute('hidden', '');
    applyButton.disabled = false;
    current = null;
  }  function openDialog(box, action) {
    current = { box, action, findingId: box.dataset.findingId };
    const publish = action === 'publish';
    reasonField.hidden = publish;
    scopeField.hidden = publish;
    expiresField.hidden = action !== 'bypass';
    confirmationField.hidden = !publish;
    reason.value = ''; expires.value = ''; confirmation.value = '';
    document.getElementById('dialog-title').textContent = publish ? 'Publish comment to PR' : action === 'falsePositive' ? 'Mark false positive' : 'Bypass finding';
    document.getElementById('dialog-description').textContent = publish ? `This creates one real inline PR thread. Type ${current.findingId} to confirm.` : 'This decision will suppress matching rule and file findings in future reviews for the selected scope.';
    applyButton.textContent = publish ? 'Publish to PR' : 'Apply';
    applyButton.disabled = false;
    modal.hidden = false;
    modal.removeAttribute('hidden');
    setTimeout(() => (publish ? confirmation : reason).focus(), 0);
  }
  document.addEventListener('click', async event => {
    const button = event.target.closest('[data-action]');
    if (!button) return;
    const box = button.closest('.comment-box');
    if (!interactive) { location.href = `${dashboardUrl}#${box.id}`; return; }
    const action = button.dataset.action;
    if (action === 'restore') {
      try { await sendAction({ action, findingId: box.dataset.findingId }); } catch (error) { showToast(error.message, true); }
      return;
    }
    openDialog(box, action);
  });
  document.getElementById('cancel-action').addEventListener('click', closeDialog);
  applyButton.addEventListener('click', async () => {
    if (!current || applyButton.disabled) return;
    const payload = { action: current.action, findingId: current.findingId, reason: reason.value.trim(), scope: scope.value, expiresAt: expires.value, confirmation: confirmation.value.trim() };
    if (current.action !== 'publish' && !payload.reason) { showToast('Reason is required.', true); return; }
    if (current.action === 'publish' && payload.confirmation.toUpperCase() !== current.findingId.toUpperCase()) { showToast('Finding ID does not match.', true); return; }
    applyButton.disabled = true;
    const progressMessage = current.action === 'publish' ? 'Publishing comment to PR...' : 'Saving finding decision...';
    closeDialog();
    showToast(progressMessage);
    try { await sendAction(payload); } catch (error) { showToast(error.message, true); }
  });  if (interactive) fetch(`/api/findings?review=${encodeURIComponent(review)}`).then(response => response.json()).then(data => (data.findings || []).forEach(applyState)).catch(error => showToast(error.message, true));
})();
</script>
'@)
[void]$html.AppendLine('</main></div></body></html>')
[IO.File]::WriteAllText($OutputPath, $html.ToString(), $utf8)
Write-Output $OutputPath
