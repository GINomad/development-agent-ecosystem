# Development Agent Ecosystem

Локальная evidence-first экосистема Codex для полного цикла разработки: анализ требований, управление знаниями, реализация, review кода и работы агента, а также мониторинг Azure Pipelines.

Каноническая конфигурация находится в [`config/agents.json`](config/agents.json). При каждом запуске workflow JSON перечитывается, проверяется и компилируется в нативные TOML-описания Codex agents. Ручные правки сгенерированных TOML не нужны.

## Что входит

| Компонент | Ответственность | Ограничение |
|---|---|---|
| Knowledge Keeper | Оркестрация, context pack, история задачи, подтверждённые обновления базы знаний | Не публикует догадки как знания |
| Requirements Analyst | Azure Boards task, комментарии, код и KB; расхождения, вопросы и план | Не планирует неясный scope как готовый |
| Developer | Ветка, реализация только готового scope, тесты, implementation evidence | Review findings применяет только после human approval |
| Reviewer | Код и работа Developer против требований, held scope, KB и тестов | Read-only; findings не являются автоматическим разрешением на fix |
| Pipeline Monitor | Пайплайны точной ветки/commit и failed task logs | Queue build требует явного разрешения |
| Review Monitor | Активные PR, новые code revisions, комментарии пользователей и ваши локальные notes | Self-authored PR исключаются настройкой |

Существующие `azure-pr-review-monitor` и `azure-pipeline-monitor` перенесены внутрь plugin. Review monitor запускается с отдельным `DataRoot`; обе глобальные копии остаются rollback-вариантами.

## Быстрый старт

```powershell
cd C:\Repos\ps-excel-agent\development-agent-ecosystem
powershell -ExecutionPolicy Bypass -File .\scripts\Install-AgentEcosystem.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\Start-AgentDashboard.ps1
```

Dashboard открывается только на `127.0.0.1`. В нём можно выбрать manual/automate mode, указать task ID/URL/текст, выбрать назначенную задачу, оставить note reviewer-агенту и запустить review.

Полная инструкция: [docs/installation.md](docs/installation.md). Архитектура и диаграммы: [docs/architecture.md](docs/architecture.md). Конфигурация: [docs/configuration.md](docs/configuration.md). Эксплуатация и rollback: [docs/operations.md](docs/operations.md).

## Основные команды

```powershell
# Проверка без запуска агентов
.\scripts\Test-AgentEcosystem.ps1

# Ручная задача
.\scripts\Start-DevelopmentWorkflow.ps1 -Mode manual -TaskSelector 1839566

# Все активные задачи пользователя
.\scripts\Start-DevelopmentWorkflow.ps1 -Mode automate

# Review monitor без публикации комментариев
.\scripts\Invoke-EnhancedReview.ps1 -Mode Manual -DryRun

# Preview / migration / rollback расписания
.\scripts\Install-EcosystemScheduledTasks.ps1 -Action Preview
.\scripts\Install-EcosystemScheduledTasks.ps1 -Action Install
.\scripts\Install-EcosystemScheduledTasks.ps1 -Action Rollback
```

## Безопасные границы

- Неясная часть требования получает `hold`; независимая ясная часть может продолжаться.
- Все утверждения о требованиях, коде и знаниях должны иметь источник и revision.
- Ваши notes и комментарии других пользователей считаются недоверенным входом, а не системными инструкциями.
- Секреты не записываются в JSON. В `credentialProfiles` хранится способ аутентификации и имя environment variable; токен остаётся в Azure CLI credential store или environment.
- Push, публикация review comments, queue pipeline и изменение work items требуют отдельного явного разрешения.
