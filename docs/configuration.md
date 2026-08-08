# Конфигурация

`config/agents.json` — единственный канонический файл для runtime, modes, repositories, workspaces, credential strategy, knowledge, gates и всех agents.

## Свежие изменения при старте

`Start-DevelopmentWorkflow.ps1` при каждом запуске:

1. заново читает и семантически проверяет JSON;
2. импортирует изменения seed KB без перезаписи локально изменённого managed-файла;
3. компилирует agent prompts и skills в Codex TOML;
4. устанавливает обновлённые TOML в `${CODEX_HOME}/agents`;
5. создаёт или продолжает task ledger.

Таким образом, для изменения поведения редактируйте JSON, prompt или skill в repository. Сгенерированные TOML не являются источником истины.

## Manual и automate

- `manual`: UI/CLI требует task selector. Это может быть Azure Boards ID, URL или явное текстовое описание.
- `automate`: analyst получает все активные assigned work items из настроенных `taskSources`, включая comments, но ограничивает один проход `maxTasksPerRun`.

## Расширение prompts и skills

Для agent добавьте путь в `agents[].promptPaths` или `agents[].skillPaths`. Путь может использовать `${REPO_ROOT}`, `${CODEX_HOME}`, `${STATE_ROOT}` и `${LOCALAPPDATA}`. Каждый skill обязан содержать валидный `SKILL.md`; новый skill удобно создавать из существующей папки plugin skills.

## Credentials

Общий JSON хранит:

- provider;
- режим (`azure-cli`, `gh-cli`, `environment`);
- путь к CLI;
- имя environment variable для fallback.

Plaintext `token`, `password` и `secret` запрещены runtime validator. Azure CLI credential cache или process environment остаются хранилищем секрета.

## Review comments

`includeActivePrComments` добавляет в review prompt Azure DevOps PR threads или GitHub issue/review/inline comments. `rerunWhenCommentsChange` включает hash обсуждения в revision key. Notes, введённые через dashboard, хранятся отдельно в `reviewer-notes` и присоединяются к нужному repository/PR/task.
