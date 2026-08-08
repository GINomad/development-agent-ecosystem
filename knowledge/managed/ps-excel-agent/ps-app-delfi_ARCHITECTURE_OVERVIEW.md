# PS-APP-DELFI Architecture Overview

## Project Summary
**Project Name:** ps-app-delfi (PlanningSpace Integration Delfi Agent)  
**Repository:** https://dev.azure.com/palantir-consulting/PalantirPlugins/_git/ps-app-delfi  
**Target Framework:** .NET 10.0  
**Type:** ASP.NET Core Web API + Background Services  
**Primary Purpose:** Integration Agent connecting Delfi/FDPlan and Planning Space for economic calculations

## High-Level Architecture

### System Overview
The ps-app-delfi project is an integration agent that acts as a **bidirectional bridge** between two systems:
1. **Delfi/FDPlan** - Schlumberger's field development planning platform
2. **Planning Space** - Economic calculation and analysis platform

The agent monitors FDPlan for calculation events, orchestrates data transformation, executes calculations in Planning Space, and returns results to FDPlan.

### Architectural Pattern
**Event-Driven Microservice Architecture** with the following characteristics:
- Event polling and processing pipeline
- RESTful API for external communication
- Background task processing with retry mechanisms
- State management via local database (SQLite/SQL Server)
- OAuth2 authentication for both systems
- Comprehensive telemetry and logging (OpenTelemetry)

### Core Components

#### 1. **Agent Core** (PlanningSpace.Integration.Delfi.Agent)
- **Entry Point:** ASP.NET Core Web API
- **Responsibilities:**
  - Host RESTful API controllers (v1 endpoints)
  - Bootstrap dependency injection and services
  - Manage authentication and authorization
  - Configure telemetry and monitoring
  - Host background services

#### 2. **Event Processing Pipeline**
- **EventPoller:** Continuously polls FDPlan for new events
- **EventQueueManager:** Manages in-memory queue of events to process
- **EventProcessor:** Orchestrates 30-step event processing workflow
- **CalculationManager:** Manages Planning Space calculation operations

#### 3. **Data Layer** (PlanningSpace.Integration.Delfi.DataStore)
- **DataStoreDbContext:** Entity Framework Core context
- **Storage:** Repository pattern for database operations
- **Entities:** Event, CalculationLog, Configuration, DataSourceModel, etc.
- **Database:** Supports SQLite (dev) and SQL Server (prod) with migrations

#### 4. **Client Libraries**
- **DelfiClient:** HTTP client for FDPlan API operations
- **PlanningSpaceClient:** HTTP client for Planning Space API
- **DataflowClient:** Client for Dataflow-specific operations
- **CalculationOrchestrator:** Orchestrates Planning Space calculations

#### 5. **Data Conversion Layer** (PlanningSpace.Integration.Delfi.Conversions)
- Format converters between FDPlan and Planning Space data models
- JSON schema validation
- Support for multiple format versions (Economics 1.4-1.8, Dataflow 2.0-2.5)

#### 6. **Utilities** (PlanningSpace.Integration.Utilities)
- Network throttling and retry mechanisms
- Common utilities and helpers

### Integration Points

#### FDPlan API
- **Base URL:** https://eu-api.delfi.slb.com/fdplan/
- **Authentication:** OAuth2 client credentials flow
- **Key Operations:**
  - Poll for computation events
  - Download input data (production forecast, CAPEX, OPEX, economic frameworks)
  - Upload calculation results
  - Post-process event status updates

#### Planning Space API
- **Base URL:** Configurable (e.g., https://ps-uat01.qdev.net/)
- **Authentication:** OAuth2 with JWT bearer tokens
- **Key Operations:**
  - Create/clone hierarchies
  - Submit calculation jobs
  - Poll for job completion
  - Retrieve calculation results
  - Manage projects, variables, and aggregations

### Data Flow (High-Level)

```
1. FDPlan Event Created → Agent Polls Event
2. Agent Downloads Input Data from FDPlan
3. Agent Converts FDPlan Data to Planning Space Format
4. Agent Submits Calculation to Planning Space
5. Agent Polls Planning Space for Completion
6. Agent Retrieves Results from Planning Space
7. Agent Converts Results to FDPlan Format
8. Agent Uploads Results to FDPlan
9. Agent Updates Event Status in FDPlan
10. Agent Logs and Archives (optional cleanup)
```

### Event Processing Steps (30 Steps Total)
The EventProcessor orchestrates all steps sequentially:
1. Validate event structure
2. Download input data containers
3. Parse economic framework
4. Transform data models
5. Create/clone hierarchy in Planning Space
6. Upload variables and aggregations
7. Submit calculation job
8. Monitor job progress
9. Handle calculation errors
10. Retrieve calculation results
11. Convert results to FDPlan format
12. Upload results to FDPlan
13. Update event status
... (and more error handling, retry, cleanup steps)

### Key Design Patterns

1. **Repository Pattern** - Storage class abstracts database operations
2. **Factory Pattern** - Provider classes for data converters
3. **Strategy Pattern** - Different conversion strategies for data formats
4. **Dependency Injection** - All services registered in Startup.cs
5. **Retry/Circuit Breaker** - Network resilience with configurable backoff
6. **Throttling** - Rate limiting to prevent API overload

### Configuration Management
- **appsettings.json** - Base configuration
- **appsettings.Defaults.json** - Default settings (UI-editable)
- **appsettings.{Environment}.json** - Environment-specific overrides
- **Azure Key Vault** - Secrets (connection strings, API keys, client secrets)
- **Database Settings** - Runtime settings stored in database

### Background Services
1. **IntegrationMonitorHostedService** - Orchestrates event polling and processing
2. **RegisterSyncSchedulerHostedService** - Schedules register synchronization tasks
3. **BackgroundTaskManager** - Manages retry of failed tasks

### API Controllers (v1 Namespace)
- **StatusController** - Health checks and system status
- **ConfigurationController** - Agent configuration management
- **DataSourceController** - Data source management
- **EventLogsController** - Event history and logs
- **OpportunityController** - Opportunity data processing
- **RegisterController** - Register data synchronization
- **ScenarioController** - Scenario management
- **SettingsController** - Runtime settings
- **StudyController** - Study data operations
- **VersionController** - Agent version information

### Observability

#### Telemetry (OpenTelemetry)
- **Traces:** Distributed tracing for request flows
- **Metrics:** Performance counters and custom metrics
- **Logs:** Structured logging with multiple levels
- **Exporters:** Console, File, OTLP, Azure Monitor

#### Monitoring
- **IntegrationMonitor** - Tracks processing metrics
- **CalculationLogService** - Logs calculation progress
- Custom performance counters

### Security
- **JWT Bearer Authentication** - For API access
- **OAuth2 Client Credentials** - For service-to-service auth
- **Azure Key Vault** - Secrets management
- **CORS Configuration** - Cross-origin request handling
- **User Group Claims** - Authorization based on AD groups

### Deployment
- **IIS Hosting** - ASP.NET Core Runtime 10.0 Hosting Bundle required
- **Kestrel** - Direct hosting on HTTPS (localhost:5000 default)
- **Docker Support** - Container deployment supported
- **Azure** - Cloud deployment with Key Vault integration

### Error Handling
- **Transient Errors:** Automatic retry with exponential backoff
- **Permanent Errors:** Logged and event marked as failed
- **Backlog Tasks:** Failed cleanup tasks retried for 24 hours
- **Cancellation Support:** Manual event cancellation via API

### Performance Optimizations
- **HTTP Compression** - gzip/deflate for network efficiency
- **Throttling** - Configurable rate limiting (default: 100 req/s)
- **Degraded Mode** - Automatic rate reduction on 429 responses
- **Parallel Processing** - Multiple events can be processed concurrently
- **Incremental Models** - Support for incremental data updates

### Testing Strategy
- **Unit Tests:** MSTest with Moq for mocking
- **Test Projects:**
  - AgentTests
  - DataStoreTests
  - CalculationOrchestratorTests
  - ConversionsTests
  - DelfiClientTests
  - DataflowClientTests
  - etc.

## Relationship to ps-excel-agent
Both projects are part of the **PlanningSpace Integration Ecosystem**:
- **ps-excel-agent:** Excel-based data import/export for Planning Space
- **ps-app-delfi:** FDPlan integration agent for Planning Space
- **Shared Concerns:** Both interact with Planning Space APIs, handle authentication, manage data transformations
- **Potential Integration:** ps-excel-agent could potentially import/export data processed by ps-app-delfi through Planning Space

### Common Components
- Both use RESTful APIs to communicate with Planning Space
- Both handle OAuth2 authentication
- Both perform data format conversions
- Both use configuration files for settings management
- Both target modern .NET frameworks (.NET 10)

## Key Technologies
- **.NET 10.0** - Target framework
- **ASP.NET Core** - Web framework
- **Entity Framework Core** - ORM
- **Swashbuckle** - Swagger/OpenAPI documentation
- **OpenTelemetry** - Observability
- **Azure SDK** - Key Vault and monitoring
- **Aucerna.Calculation.Advanced** - Advanced calculation library
- **Aucerna.Integration.Economics** - Economics integration library
- **JsonSchema.Net** - JSON schema validation
- **MSTest** - Testing framework
- **Moq** - Mocking framework
