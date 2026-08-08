# Эксплуатация и rollback

## Ежедневная работа

Запуск UI:

```powershell
.\scripts\Start-AgentDashboard.ps1
```

Из UI:

- выберите manual или automate;
- в manual укажите ID/URL задачи или выберите её из assigned inbox;
- при необходимости добавьте instruction;
- reviewer note можно привязать к repository, PR и task;
- `Запустить review` читает код активных PR, комментарии пользователей и notes.

## Review approval gate

Reviewer только записывает findings. Решение человека фиксируется отдельно:

```powershell
.\scripts\Set-ReviewDecision.ps1 -TaskId task-1839566 -FindingId R-001 -Decision approved -Reason 'Исправить до merge'
```

Допустимы `approved`, `rejected`, `deferred`. Developer не должен применять finding без `approved`.

## Scheduled tasks

- `Development Ecosystem - PR Review Updates` — poll active assigned PRs;
- `Development Ecosystem - PR Review Daily` — полный daily pass;
- `Development Ecosystem - PR Review Dashboard` — loopback report server at logon.

## Rollback

```powershell
.\scripts\Install-EcosystemScheduledTasks.ps1 -Action Rollback
```

Rollback отключает новые задачи и включает legacy `Codex PR Review - ...`. Он не удаляет новый plugin, новый DataRoot или глобальный `azure-pr-review-monitor`, поэтому диагностика и обратное переключение остаются возможными.

После стабилизации глобальные копии `azure-pr-review-monitor` и `azure-pipeline-monitor` можно удалить вручную отдельным решением. Автоматически они не удаляются.

## Диагностика

```powershell
.\scripts\Test-AgentEcosystem.ps1
.\scripts\Invoke-EnhancedReview.ps1 -Mode Manual -DryRun
.\scripts\Sync-ReviewMonitorConfig.ps1
```

Если новый review dry-run завершается ошибкой, legacy scheduled tasks не отключаются. Если ошибка возникает после частичного отключения, install-script повторно включает уже отключённые legacy-задачи.
