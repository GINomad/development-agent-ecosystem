# Finding Management

Each review writes stable finding IDs into Markdown and a `.findings.json` sidecar. The sidecar records the provider and configured repository id so dispositions and publications cannot collide across providers.

Use the dashboard or command-line manager:

```powershell
$manager = "$HOME/.codex/skills/azure-pr-review-monitor/scripts/manage_review_findings.ps1"
& $manager -Action List
& $manager -Action Bypass -FindingId 'RVW-...' -Scope repository -Reason 'Accepted design'
& $manager -Action FalsePositive -FindingId 'RVW-...' -Scope pull-request -Reason 'Validated by gateway'
& $manager -Action Restore -FindingId 'RVW-...'
& $manager -Action Publish -FindingId 'RVW-...' -WhatIf
& $manager -Action Publish -FindingId 'RVW-...'
```

Publication resolves the provider from the sidecar and dispatches to Azure DevOps or GitHub. It is never automatic and a local record blocks accidental duplicates unless `-ForcePublish` is explicit.

Local files under `%LOCALAPPDATA%\Codex\azure-pr-review-monitor`:

- `finding-dispositions.json`: bypass and false-positive decisions.
- `published-comments.json`: externally published comment identifiers.
- `reports\*.findings.json`: complete finding metadata.
