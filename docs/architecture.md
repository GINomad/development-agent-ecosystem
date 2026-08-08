# Архитектура и ответственности

## Взаимодействие

```mermaid
flowchart LR
    U[Developer / Dashboard] --> K[Knowledge Keeper]
    A[Azure Boards + comments] --> RA[Requirements Analyst]
    C[Codebase] --> RA
    KB[(Versioned Knowledge)] <--> K
    K --> RA
    RA -->|ready scope + held scope + questions| K
    K --> D[Developer]
    RA --> D
    D -->|plan, code, tests, evidence| K
    D --> R[Reviewer]
    K --> R
    RA --> R
    PR[Active PR code + user comments + local notes] --> R
    R -->|findings| K
    R -->|findings, no auto-fix| D
    U -->|approve / reject / defer| G{Review decision gate}
    G -->|approved only| D
    D --> P[Azure Pipeline Monitor]
    P -->|exact commit status + failed logs| K
    K --> KB
```

## Жизненный цикл задачи

```mermaid
sequenceDiagram
    participant U as Developer
    participant K as Knowledge Keeper
    participant A as Requirements Analyst
    participant D as Developer Agent
    participant R as Reviewer Agent
    participant P as Pipeline Monitor

    U->>K: task ID / URL / instruction
    K->>A: verified context request
    A-->>K: ready scope, held scope, questions, sources
    alt есть независимый ready scope
        K->>D: approved implementation context
        D-->>K: plan, changes, tests, implementation evidence
        K->>R: requirements + held scope + implementation
        R-->>K: findings and verdict
        R-->>D: findings for visibility
        U->>K: approve / reject / defer finding
        K->>D: approved findings only
        D->>P: pushed branch and exact commit
        P-->>K: pipeline result and failure logs
        K->>K: publish verified knowledge and task history
    else весь scope заблокирован вопросами
        K-->>U: questions and explicit hold
    end
```

## Артефакты на задачу

Runtime хранит историю вне repository в `%LOCALAPPDATA%/Codex/development-agent-ecosystem/tasks/<task-id>`:

- `task.json` — identity и текущее состояние;
- `task-ledger.jsonl` — append-only диалог и события всех agents;
- `context-pack.json` — выданный Knowledge Keeper контекст;
- `requirements-analysis.json` — ready/held scope, gaps и вопросы;
- `implementation-plan.json`, `implementation-result.json`;
- `review-result.json`, `review-decisions.json`;
- `pipeline-result.json`, `knowledge-update.json`.

Schemas находятся в `config/schemas`. Knowledge Keeper публикует в versioned KB только утверждения с обязательными evidence fields.
