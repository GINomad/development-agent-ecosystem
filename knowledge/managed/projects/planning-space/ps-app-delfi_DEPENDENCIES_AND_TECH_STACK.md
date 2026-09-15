# PS-APP-DELFI: Project Dependencies and Technology Stack

## Project Context
**Project:** ps-app-delfi (PlanningSpace Integration Delfi Agent)  
**Target Framework:** .NET 10.0  
**Repository:** https://dev.azure.com/palantir-consulting/PalantirPlugins/_git/ps-app-delfi

---

## Solution Structure

### Production Projects

1. **PlanningSpace.Integration.Delfi.Agent** (Main API)
2. **PlanningSpace.Integration.Delfi.DataStore** (Database layer)
3. **PlanningSpace.Integration.Delfi.DataflowClient** (Dataflow API client)
4. **PlanningSpace.Integration.Delfi.DelfiClient** (FDPlan API client)
5. **PlanningSpace.Integration.Delfi.PlanningSpaceClient** (Planning Space API client)
6. **PlanningSpace.Integration.Delfi.CalculationOrchestrator** (Calculation operations)
7. **PlanningSpace.Integration.Delfi.Conversions** (Data format converters)
8. **PlanningSpace.Integration.Delfi.AdvancedCalculations** (Advanced calculation support)
9. **PlanningSpace.Integration.Common** (Shared models)
10. **PlanningSpace.Integration.Delfi.Utilities** (Common utilities)
11. **PlanningSpace.Integration.Delfi.FDPlanConfigUtil** (Configuration utility)
12. **PlanningSpace.Integration.Delfi.DataStore.Migrations.SqlServer** (SQL Server migrations)
13. **PlanningSpace.Integration.Delfi.DataStore.Migrations.Sqlite** (SQLite migrations)

### Test Projects

1. **PlanningSpace.Integration.Delfi.AgentTests**
2. **PlanningSpace.Integration.Delfi.DataStoreTests**
3. **PlanningSpace.Integration.Delfi.PlanningSpaceClientTests**
4. **PlanningSpace.Integration.Delfi.AdvancedCalculationsTests**
5. **PlanningSpace.Integration.Delfi.ConversionsTests**
6. **PlanningSpace.Integration.Delfi.DelfiClientTests**
7. **PlanningSpace.Integration.CalculationOrchestratorTests**
8. **PlanningSpace.Integration.Delfi.DataflowClientTests**
9. **PlanningSpace.Integration.Delfi.FDPlanConfigUtilTests**
10. **PlanningSpace.Integration.UtilitiesTests**

---

## NuGet Package Dependencies

### Agent Project Dependencies

#### Azure & Cloud Services
```xml
<PackageReference Include="Azure.Extensions.AspNetCore.Configuration.Secrets" Version="1.5.1" />
<PackageReference Include="Azure.Identity" Version="1.21.0" />
<PackageReference Include="Azure.Monitor.OpenTelemetry.Exporter" Version="1.8.1" />
<PackageReference Include="Azure.Security.KeyVault.Certificates" Version="4.8.0" />
<PackageReference Include="Azure.Security.KeyVault.Secrets" Version="4.11.0" />
```

**Purpose:**
- Configuration from Azure Key Vault
- Managed Identity authentication
- Telemetry export to Azure Monitor
- Certificate and secret management

#### ASP.NET Core & Web
```xml
<PackageReference Include="Microsoft.AspNetCore.Authentication.JwtBearer" Version="10.0.8" />
<PackageReference Include="Microsoft.VisualStudio.Azure.Containers.Tools.Targets" Version="1.23.0" />
```

**Purpose:**
- JWT Bearer token authentication
- Docker container support

#### OpenTelemetry (Observability)
```xml
<PackageReference Include="OpenTelemetry.Exporter.Console" Version="1.15.3" />
<PackageReference Include="OpenTelemetry.Exporter.OpenTelemetryProtocol" Version="1.15.3" />
<PackageReference Include="OpenTelemetry.Extensions.Hosting" Version="1.15.3" />
<PackageReference Include="OpenTelemetry.Instrumentation.AspNetCore" Version="1.15.2" />
<PackageReference Include="OpenTelemetry.Instrumentation.EntityFrameworkCore" Version="1.10.0-beta.1" />
<PackageReference Include="OpenTelemetry.Instrumentation.Http" Version="1.15.1" />
```

**Purpose:**
- Distributed tracing (traces)
- Performance metrics
- Structured logging
- HTTP request instrumentation
- EF Core query instrumentation

#### Swagger/OpenAPI
```xml
<PackageReference Include="Swashbuckle.AspNetCore" Version="10.1.7" />
<PackageReference Include="Swashbuckle.AspNetCore.Annotations" Version="10.1.7" />
```

**Purpose:**
- API documentation generation
- Swagger UI for testing
- OpenAPI spec generation

#### System Libraries
```xml
<PackageReference Include="System.IO.Hashing" Version="10.0.8" />
```

**Purpose:**
- Hashing algorithms for data integrity

---

### Calculation Orchestrator Dependencies

#### Aucerna Libraries (Proprietary)
```xml
<PackageReference Include="Aucerna.Calculation.Advanced" Version="20.4.18.1" />
<PackageReference Include="Aucerna.Integration.Economics" Version="20.4.2" />
```

**Purpose:**
- Advanced calculation engine
- Economics calculation integration
- Business logic for Planning Space calculations

**Note:** These are proprietary libraries for economic modeling and calculations

#### Microsoft Extensions
```xml
<PackageReference Include="Microsoft.Extensions.Logging.Abstractions" Version="10.0.8" />
```

**Purpose:**
- Logging abstractions

---

### Conversions Project Dependencies

#### JSON Schema Validation
```xml
<PackageReference Include="JsonSchema.Net" Version="9.2.1" />
```

**Purpose:**
- Validate JSON against schemas
- Ensure data format compliance
- Support multiple schema versions

#### Logging
```xml
<PackageReference Include="Microsoft.Extensions.Logging.Abstractions" Version="10.0.8" />
```

---

### Advanced Calculations Dependencies

```xml
<PackageReference Include="Aucerna.Calculation.Advanced" Version="20.4.18.1" />
```

**Purpose:**
- Advanced calculation features
- Extended economic models

---

### Test Project Dependencies

#### Test Frameworks
```xml
<PackageReference Include="Microsoft.NET.Test.Sdk" Version="18.5.1" />
<PackageReference Include="MSTest.TestAdapter" Version="4.2.3" />
<PackageReference Include="MSTest.TestFramework" Version="4.2.3" />
```

**Purpose:**
- MSTest testing framework
- Test adapter for Visual Studio
- Test execution and reporting

#### Mocking
```xml
<PackageReference Include="Moq" Version="4.20.72" />
```

**Purpose:**
- Mock dependencies in unit tests
- Behavior verification
- Test isolation

#### Code Coverage
```xml
<PackageReference Include="coverlet.collector" Version="10.0.1">
  <PrivateAssets>all</PrivateAssets>
  <IncludeAssets>runtime; build; native; contentfiles; analyzers; buildtransitive</IncludeAssets>
</PackageReference>
```

**Purpose:**
- Code coverage collection
- Coverage reporting

#### Configuration
```xml
<PackageReference Include="Microsoft.Extensions.Configuration" Version="10.0.8" />
```

**Purpose:**
- Configuration support in tests

---

## Project References (Internal Dependencies)

### Agent Project References
```xml
<ProjectReference Include="..\PlanningSpace.Integration.Delfi.DataStore\PlanningSpace.Integration.Delfi.DataStore.csproj" />
<ProjectReference Include="..\PlanningSpace.Integration.Delfi.DelfiClient\PlanningSpace.Integration.Delfi.DelfiClient.csproj" />
<ProjectReference Include="..\PlanningSpace.Integration.Delfi.PlanningSpaceClient\PlanningSpace.Integration.PlanningSpaceClient.csproj" />
<ProjectReference Include="..\PlanningSpace.Integration.Delfi.CalculationOrchestrator\PlanningSpace.Integration.CalculationOrchestrator.csproj" />
<ProjectReference Include="..\PlanningSpace.Integration.Delfi.Conversions\PlanningSpace.Integration.Delfi.Conversions.csproj" />
<ProjectReference Include="..\PlanningSpace.Integration.Delfi.DataflowClient\PlanningSpace.Integration.Delfi.DataflowClient.csproj" />
<ProjectReference Include="..\PlanningSpace.Integration.Delfi.AdvancedCalculations\PlanningSpace.Integration.AdvancedCalculations.csproj" />
<ProjectReference Include="..\PlanningSpace.Integration.Delfi.Utilities\PlanningSpace.Integration.Utilities.csproj" />
```

### Conversions Project References
```xml
<ProjectReference Include="..\PlanningSpace.Integration.Delfi.DelfiClient\PlanningSpace.Integration.Delfi.DelfiClient.csproj" />
<ProjectReference Include="..\PlanningSpace.Integration.Delfi.CalculationOrchestrator\PlanningSpace.Integration.CalculationOrchestrator.csproj" />
<ProjectReference Include="..\PlanningSpace.Integration.Delfi.DataflowClient\PlanningSpace.Integration.Delfi.DataflowClient.csproj" />
```

---

## Dependency Graph

```
Agent (Main Entry Point)
├── DataStore (EF Core, SQLite/SQL Server)
├── DelfiClient (FDPlan API)
├── PlanningSpaceClient (Planning Space API)
├── CalculationOrchestrator
│   ├── Aucerna.Calculation.Advanced
│   └── Aucerna.Integration.Economics
├── Conversions
│   ├── DelfiClient
│   ├── CalculationOrchestrator
│   ├── DataflowClient
│   └── JsonSchema.Net
├── DataflowClient
├── AdvancedCalculations
│   └── Aucerna.Calculation.Advanced
└── Utilities
```

---

## Technology Stack Summary

### Languages & Frameworks
- **C# 12** - Primary language
- **.NET 10.0** - Target framework
- **ASP.NET Core 10.0** - Web framework
- **Entity Framework Core 10.0** - ORM (implicit via .NET 10)

### Cloud & Infrastructure
- **Azure Key Vault** - Secrets management
- **Azure Managed Identity** - Authentication
- **Azure Monitor** - Telemetry export
- **Docker** - Container deployment

### Data Storage
- **SQLite** - Development/testing database
- **SQL Server** - Production database
- **Entity Framework Core** - Database access

### API & Communication
- **REST API** - HTTP communication
- **JSON** - Data serialization
- **Swagger/OpenAPI** - API documentation
- **JWT** - Authentication tokens
- **OAuth2** - Authorization protocol

### Observability
- **OpenTelemetry** - Telemetry standard
  - Traces (distributed tracing)
  - Metrics (performance counters)
  - Logs (structured logging)
- **Console Exporter** - Development logging
- **OTLP Exporter** - Standard telemetry protocol
- **Azure Monitor Exporter** - Production monitoring

### Testing
- **MSTest** - Unit testing framework
- **Moq** - Mocking framework
- **Coverlet** - Code coverage

### Third-Party Libraries
- **Aucerna.Calculation.Advanced** - Calculation engine
- **Aucerna.Integration.Economics** - Economics integration
- **JsonSchema.Net** - JSON schema validation

---

## Runtime Requirements

### Development
- **.NET 10.0 SDK** - Development tools
- **Visual Studio 2026** (18.7+) or VS Code
- **SQL Server Express** or **SQLite** - Database
- **Postman** (optional) - API testing

### Production
- **ASP.NET Core Runtime 10.0 Hosting Bundle** - Server hosting
- **IIS** (optional) - Web server
  - URL Rewrite extension required
- **SQL Server** - Production database
- **Azure subscription** - Key Vault and monitoring

### External Systems
- **FDPlan (Delfi) API** - https://eu-api.delfi.slb.com/fdplan/
- **Planning Space API** - Configurable endpoint
- **Schlumberger CSI** - OAuth2 token endpoint

---

## Configuration Dependencies

### appsettings.json Sections
```json
{
  "KeyVault": { ... },
  "UI": { ... },
  "PlanningSpace": {
	"BaseUrl": "...",
	"Tenant": "...",
	"NetworkRequests": { ... },
	"CalculationJobs": { ... },
	"Throttling": { ... }
  },
  "FDPlan": {
	"BaseUrl": "...",
	"DataUrl": "...",
	"NetworkRequests": { ... }
  },
  "Database": {
	"SqliteDbFilePath": "...",
	"ConnectionString": "..." (from Key Vault)
  },
  "OpenTelemetry": {
	"Exporters": [...],
	"OTLP": { ... },
	"AzureMonitor": { ... }
  }
}
```

### Environment Variables
- `ASPNETCORE_ENVIRONMENT` - Environment name (Development, Production, etc.)
- `AZURE_CLIENT_ID` - Managed Identity client ID
- `AZURE_TENANT_ID` - Azure tenant ID
- `AZURE_CLIENT_SECRET` - Service principal secret (if not using Managed Identity)

---

## Network Dependencies

### Outbound Connections Required

#### FDPlan (Delfi)
- **Base URL:** https://csi.slb.com/v2/token (OAuth)
- **Data URL:** https://eu-api.delfi.slb.com/fdplan/
- **Ports:** 443 (HTTPS)

#### Planning Space
- **Configurable Base URL** (e.g., https://ps-uat01.qdev.net/)
- **Ports:** 443 (HTTPS)

#### Azure Services
- **Key Vault:** https://{vault-name}.vault.azure.net/
- **Azure Monitor:** https://{region}.in.applicationinsights.azure.com/
- **Ports:** 443 (HTTPS)

#### Telemetry (Optional)
- **OTLP Endpoint:** Configurable (e.g., http://otel-collector:4317)
- **Ports:** Configurable (typically 4317 for gRPC, 4318 for HTTP)

---

## Version Compatibility

### Supported File Formats

#### Economics Frameworks
- **1.4** - Legacy format
- **1.5** - Legacy format
- **1.6** - Legacy format
- **1.7** - Current format
- **1.8** - Latest format

#### Dataflow Formats
- **2.0** - Legacy format
- **2.1** - Legacy format
- **2.2** - Legacy format
- **2.3** - Current format
- **2.4** - Current format
- **2.5** - Latest format

### FDPlan API Versions
- **Evaluation API:** alpha/v1
- **Data Sources API:** alpha/v2

### Planning Space API
- **Version Detection:** `IVersionController.GetVersion()`
- **Minimum Supported:** (Depends on Aucerna.Integration.Economics version)

---

## Build Configuration

### Debug Configuration
```xml
<PropertyGroup Condition="'$(Configuration)|$(Platform)'=='Debug|AnyCPU'">
  <DebugType>full</DebugType>
  <DebugSymbols>true</DebugSymbols>
</PropertyGroup>
```

### Target Framework
```xml
<PropertyGroup>
  <TargetFramework>net10.0</TargetFramework>
  <ImplicitUsings>enable</ImplicitUsings>
  <Nullable>enable</Nullable> (in some projects)
</PropertyGroup>
```

---

## Embedded Resources

### Conversions Project
```xml
<EmbeddedResource Include="FileFormats\dataflow-2.0.jsonc" />
<EmbeddedResource Include="FileFormats\dataflow-2.1.jsonc" />
<EmbeddedResource Include="FileFormats\dataflow-2.2.jsonc" />
<EmbeddedResource Include="FileFormats\dataflow-2.3.jsonc" />
<EmbeddedResource Include="FileFormats\dataflow-2.4.jsonc" />
<EmbeddedResource Include="FileFormats\dataflow-2.5.jsonc" />
<EmbeddedResource Include="FileFormats\economics-1.4.jsonc" />
<EmbeddedResource Include="FileFormats\economics-1.5.jsonc" />
<EmbeddedResource Include="FileFormats\economics-1.6.jsonc" />
<EmbeddedResource Include="FileFormats\economics-1.7.jsonc" />
<EmbeddedResource Include="FileFormats\economics-1.8.jsonc" />
```

**Purpose:** JSON schema files for validation

### Agent Project
```xml
<EmbeddedResource Include="Data\computation-specs.json" />
<EmbeddedResource Include="Data\data-source-types.json" />
<EmbeddedResource Include="Data\data-types.json" />
<EmbeddedResource Include="Data\workflow-specs.json" />
```

**Purpose:** Static configuration data for FDPlan initialization

---

## Licensing & Proprietary Dependencies

### Proprietary Components
- **Aucerna.Calculation.Advanced** - Requires Aucerna/Quorum license
- **Aucerna.Integration.Economics** - Requires Aucerna/Quorum license

### Open Source Dependencies
All other NuGet packages are open source with permissive licenses:
- MIT License: JsonSchema.Net, Moq, Swashbuckle
- Apache 2.0: OpenTelemetry, Azure SDK
- Microsoft License: .NET libraries

---

## Deployment Package Dependencies

### Hosting Bundle Contents
- ASP.NET Core Runtime 10.0
- .NET Runtime 10.0
- IIS integration module (optional)

### Required Certificates
- HTTPS certificate for Kestrel or IIS
- Azure Key Vault access certificate (if using certificate-based auth)
- FDPlan client certificate (if required)

---

## Development Tool Dependencies

### Visual Studio Extensions
- Azure tools (Azure Key Vault integration)
- Docker tools (container deployment)
- OpenAPI/Swagger tools (API testing)

### Optional Tools
- Postman - API testing
- Azure Storage Explorer - Azure diagnostics
- SQL Server Management Studio - Database management
- Docker Desktop - Container development

---

## Summary

**Core Technologies:**
- .NET 10.0 with C# 12
- ASP.NET Core Web API
- Entity Framework Core
- OpenTelemetry observability
- Azure cloud services

**Key Dependencies:**
- Aucerna calculation libraries (proprietary)
- Azure SDK for cloud integration
- OpenTelemetry for monitoring
- JsonSchema.Net for validation
- MSTest + Moq for testing

**Total Projects:** 23 (13 production, 10 test)  
**Total NuGet Packages:** ~50 across all projects  
**External APIs:** FDPlan (Delfi), Planning Space, Azure Key Vault
