# Additional Review Instructions

The monitor always loads its bundled review checklist. Before each Codex review, it also loads configured review skills and agent-specific prompt files, then supplies the complete instruction set before the untrusted Git patch.

## Default folders

- `%LOCALAPPDATA%\Codex\azure-pr-review-monitor\review-skills`
- `%LOCALAPPDATA%\Codex\azure-pr-review-monitor\review-prompts`

Put each skill in its own directory with a `SKILL.md` file:

```text
review-skills/
  company-dotnet-review/
    SKILL.md
    references/
```

Put focused `.md` or `.txt` instruction files in `review-prompts`. These are agent-specific prompt fragments, not the deprecated Codex custom-prompt feature.

The monitor scans both folders recursively on every run. No restart is required.

## External paths

Add optional paths to `%LOCALAPPDATA%\Codex\azure-pr-review-monitor\config.json`:

```json
{
  "reviewSkillPaths": [
    "%USERPROFILE%\\.codex\\skills\\company-dotnet-review\\SKILL.md"
  ],
  "reviewPromptPaths": [
    "C:\\Engineering\\review-prompts"
  ]
}
```

Configured paths must exist. Skill files must be named `SKILL.md`; prompt files must use `.md` or `.txt`.

## Native Codex skills

A native Codex skill is a directory containing `SKILL.md` with `name` and `description` front matter. Install one under `%USERPROFILE%\.codex\skills\<skill-name>`. To make this review monitor load it on every review, also add its `SKILL.md` path to `reviewSkillPaths` or copy the skill into the monitor's `review-skills` folder.

The monitor does not load every installed Codex skill automatically because unrelated skills add noise and may conflict with review policy.

## Limits and verification

- Up to 64 additional files.
- Up to 128 KiB per file.
- Up to 256 KiB total.
- Empty files are ignored.
- Loaded file paths appear in `latest-summary.md`.

Run a fresh validation review after changing instructions:

```powershell
& "$HOME/.codex/skills/azure-pr-review-monitor/scripts/run_pr_review_monitor.ps1" -Mode Manual -ForceReview
```

Additional instructions may specialize review behavior but cannot override the monitor's read-only execution and publication safeguards.
