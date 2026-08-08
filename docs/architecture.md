# Architecture and responsibilities

The editable vector overview is available below and as a standalone file: [ecosystem-architecture.svg](assets/ecosystem-architecture.svg).

![Development Agent Ecosystem architecture](assets/ecosystem-architecture.svg)

## Component interaction

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
    R -->|findings, no automatic fix| D
    U -->|approve / reject / defer| G{Review decision gate}
    G -->|approved findings only| D
    D --> P[Azure Pipeline Monitor]
    P -->|exact commit status + failed logs| K
    K --> KB
```

## Task lifecycle

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
    alt independent ready scope exists
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
    else all scope is blocked by unanswered questions
        K-->>U: questions and explicit hold
    end
```

## Per-task artifacts

Runtime task history is stored outside the repository under `%LOCALAPPDATA%/Codex/development-agent-ecosystem/tasks/<task-id>`:

- `task.json`: task identity and current state;
- `task-ledger.jsonl`: append-only communication and events from every agent;
- `context-pack.json`: context selected by Knowledge Keeper;
- `requirements-analysis.json`: ready scope, held scope, gaps, and questions;
- `implementation-plan.json` and `implementation-result.json`;
- `review-result.json` and `review-decisions.json`;
- `pipeline-result.json` and `knowledge-update.json`.

Schemas are stored under `config/schemas`. Knowledge Keeper may publish only evidence-backed claims with all required evidence fields.
