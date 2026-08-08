# Interactive Review Dashboard

Open the latest report:

```powershell
& "$HOME/.codex/skills/azure-pr-review-monitor/scripts/open_review_dashboard.ps1"
```

The dashboard listens only on `127.0.0.1:47831`. Its hidden server process remains available after the launching console closes.

Use the previous/next buttons or `[` and `]` to move between diff hunks. Every finding supports:

- `Bypass`: suppress matching rule and file findings for repository or PR scope.
- `False positive`: record an audited false-positive disposition.
- `Restore`: make the finding actionable again.
- `Publish to PR`: create one real inline comment in Azure DevOps or GitHub after exact finding-ID confirmation.

State-changing local requests use a per-process session token. Publication is never automatic, and duplicate publication for the same provider, repository, finding, and source commit is blocked.
