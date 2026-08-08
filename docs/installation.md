# Установка

## Требования

- Windows PowerShell 5.1 или PowerShell 7;
- Codex CLI с поддержкой plugins и custom agents;
- Azure CLI с доступом к организации Azure DevOps;
- локальная рабочая копия каждого настроенного repository.

Для текущей конфигурации Azure CLI расположен в `C:/Program Files/Microsoft SDKs/Azure/CLI2/wbin/az.cmd`. Секреты не копируются в репозиторий.

## 1. Проверьте общую конфигурацию

Откройте `config/agents.json` и проверьте:

- `repositories[].localWorkspace`, Azure organization/project/repository и reviewer;
- `taskSources[]` для assigned work items;
- `credentialProfiles[]` — только CLI/environment strategy, без token/password;
- `operation.mode`: `manual` или `automate`;
- `knowledge.seedSources[]` и `knowledge.managedRoot`.

## 2. Установите plugin и agents

```powershell
cd C:\Repos\ps-excel-agent\development-agent-ecosystem
powershell -ExecutionPolicy Bypass -File .\scripts\Install-AgentEcosystem.ps1
```

Installer выполняет:

1. идемпотентный read-only import начальной KB;
2. компиляцию пяти custom agents из свежего JSON;
3. создание derived-конфигурации review monitor в `%LOCALAPPDATA%`;
4. локальные проверки;
5. регистрацию repository как Codex marketplace и установку plugin.

Начальный источник `C:\Repos\AI Knowledge\ps_excel_agent` не изменяется. Управляемая версия хранится в `knowledge/managed/ps-excel-agent` этого repository; provenance находится в `.knowledge-import.json`.

## 3. Запустите интерфейс

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Start-AgentDashboard.ps1
```

UI доступен только на loopback. URL содержит случайный session token, API дополнительно требует этот token в header.

## 4. Переключите расписание после dry-run

```powershell
.\scripts\Install-EcosystemScheduledTasks.ps1 -Action Preview
.\scripts\Install-EcosystemScheduledTasks.ps1 -Action Install
```

`Install` сначала запускает новый monitor с `-DryRun`. Затем регистрирует три задачи `Development Ecosystem - ...`, проверяет их наличие и только после этого отключает legacy-задачи `Codex PR Review - ...`. Legacy XML сохраняется в `%LOCALAPPDATA%\Codex\development-agent-ecosystem\scheduled-task-backup`.

## Проверка установки

```powershell
.\scripts\Test-AgentEcosystem.ps1 | ConvertTo-Json -Depth 8
codex plugin list
Get-ScheduledTask | Where-Object TaskName -like '*PR Review*' |
  Select-Object TaskName, State, @{n='Enabled';e={$_.Settings.Enabled}}
```
