# PS-APP-DELFI: Relationship to PS-EXCEL-AGENT

## Overview
This document describes the relationship between **ps-app-delfi** and **ps-excel-agent** projects, both part of the PlanningSpace integration ecosystem.

---

## Projects Summary

### PS-APP-DELFI
**Full Name:** PlanningSpace Integration Delfi Agent  
**Purpose:** Integration agent connecting Delfi/FDPlan and Planning Space for economic calculations  
**Type:** ASP.NET Core Web API + Background Services  
**Primary Use Case:** Automated, event-driven calculation pipeline  
**Users:** FDPlan users triggering calculations, system administrators  
**Repository:** https://dev.azure.com/palantir-consulting/PalantirPlugins/_git/ps-app-delfi

### PS-EXCEL-AGENT
**Full Name:** PlanningSpace Excel Agent  
**Purpose:** Excel-based data import/export for Planning Space  
**Type:** Excel Add-in / Integration Tool (likely)  
**Primary Use Case:** Manual data entry, ad-hoc data import/export  
**Users:** Planning Space users working with Excel spreadsheets  
**Repository:** (Located in C:\Repos\ps-excel-agent based on context)

---

## Architectural Relationship

### Common Components

#### 1. Planning Space API Integration
Both projects interact with **Planning Space APIs**:

**ps-app-delfi interfaces:**
- `IPlanningSpaceService` - Base service for PS API calls
- `ICalculationController` - Submit and monitor calculations
- `IProjectsController` - Create and manage projects
- `IVariablesController` - Upload economic variables
- `IHierarchyController` - Manage hierarchies
- `ICurrencyDeckController`, `IPriceDeckController` - Economic assumptions

**ps-excel-agent (expected interfaces):**
- Similar Planning Space API clients
- Data extraction from Planning Space
- Variable upload/download
- Project data management

**Shared Concerns:**
- OAuth2 authentication with Planning Space
- Tenant-specific URL handling
- Token management and refresh
- API retry and error handling
- Network throttling

#### 2. Authentication Pattern
Both projects likely use:
- **OAuth2** authentication flow
- **JWT Bearer tokens** for API access
- **Tenant-based** configuration (e.g., tenant="atlantis")
- **Client ID and Client Secret** management
- Optional **token delegation** for long-running operations

**ps-app-delfi pattern:**
```csharp
public interface IPlanningSpaceService : INetworkClientService
{
	string GetAuthKey();
	string GetTenantUrl();
	string GetAccessToken();
	Task<string> ExchangeTokenAsync(string userBearerToken);
}
```

**ps-excel-agent (expected similar pattern):**
- User authentication through Planning Space
- Token storage for API calls
- Session management

#### 3. Data Models and Formats
Both projects handle similar data structures:

**Common data types:**
- Economic variables (time series, scalars)
- Project hierarchies
- Calculation results
- Currency and price decks

**ps-app-delfi models:**
- `CalculationInputModel` - Calculation parameters
- `CalculationResultModel` - Calculation outputs
- `GenericVariableDataModel` - Variable data
- `HierarchyModel` - Hierarchy definitions

**ps-excel-agent (expected models):**
- Similar variable data models
- Excel-specific data representations
- Mapping between Excel ranges and PS variables

#### 4. Configuration Management
Both projects use:
- **appsettings.json** for base configuration
- **Environment-specific overrides** (Development, Production)
- **Secret management** (likely Azure Key Vault or similar)

**Common configuration sections:**
```json
{
  "PlanningSpace": {
	"BaseUrl": "https://ps-uat01.qdev.net/",
	"Tenant": "atlantis",
	"FrontEndClientId": "...",
	"NetworkRequests": {
	  "TimeoutInSeconds": 0,
	  "EnableContentCompression": true
	}
  }
}
```

---

## Functional Relationship

### Distinct Roles

#### PS-APP-DELFI Role
**Automated Integration:**
- Polls FDPlan for computation events
- Orchestrates end-to-end calculation pipeline
- Converts data between FDPlan and Planning Space formats
- Returns results to FDPlan automatically
- Runs as a background service

**Data Sources:**
- FDPlan (primary input source)
- Planning Space (calculation engine)

**Data Direction:**
- **FDPlan → ps-app-delfi → Planning Space** (input)
- **Planning Space → ps-app-delfi → FDPlan** (results)

#### PS-EXCEL-AGENT Role
**Manual Integration:**
- Allows users to work with Excel spreadsheets
- Import/export data to/from Planning Space
- Manual data entry and validation
- Ad-hoc data analysis
- User-initiated operations

**Data Sources:**
- Excel workbooks (primary input/output)
- Planning Space (data storage and calculations)

**Data Direction:**
- **Excel → ps-excel-agent → Planning Space** (import)
- **Planning Space → ps-excel-agent → Excel** (export)

---

## Potential Integration Points

### 1. Shared Data Store (Planning Space)
Both projects read from and write to **Planning Space**:

```
FDPlan Data
	↓ (via ps-app-delfi)
Planning Space Database
	↓ (via ps-excel-agent)
Excel Spreadsheets
```

**Scenario:** A user could:
1. Trigger a calculation in FDPlan
2. ps-app-delfi processes it and stores results in Planning Space
3. User opens ps-excel-agent to export the results to Excel for further analysis

### 2. Economic Data Sharing
Both handle economic data:

**ps-app-delfi processes:**
- Production forecasts
- CAPEX schedules
- OPEX schedules
- Economic frameworks
- Calculation results (NPV, IRR, etc.)

**ps-excel-agent likely handles:**
- Economic variable input from Excel
- Calculation result export to Excel
- Parameter sensitivity analysis data
- Manual overrides and adjustments

### 3. Hierarchy and Project Management
Both work with Planning Space hierarchies:

**ps-app-delfi:**
- Creates hierarchies from FDPlan scenarios
- Maps FDPlan entities to PS projects
- Clones hierarchies for calculations

**ps-excel-agent (expected):**
- Exports hierarchy structures to Excel
- Allows manual project creation from Excel
- Facilitates bulk project updates

### 4. Variable Management
Both manage Planning Space variables:

**ps-app-delfi:**
- Bulk uploads variables from FDPlan
- Time series data transformation
- Scalar variable configuration

**ps-excel-agent (expected):**
- Variable data import from Excel ranges
- Variable export to Excel tables
- Manual variable editing

---

## Complementary Workflows

### Workflow 1: FDPlan → Planning Space → Excel
```
1. FDPlan user creates calculation event
2. ps-app-delfi picks up event automatically
3. ps-app-delfi transforms data and submits to Planning Space
4. Planning Space completes calculation
5. ps-app-delfi returns results to FDPlan
6. Planning Space user opens ps-excel-agent
7. ps-excel-agent exports calculation results to Excel for presentation
```

### Workflow 2: Excel → Planning Space → FDPlan
```
1. User prepares economic assumptions in Excel
2. ps-excel-agent imports data to Planning Space
3. Data stored in Planning Space database
4. FDPlan user references that data in a scenario
5. ps-app-delfi uses the data for calculations
```

### Workflow 3: Round-trip with Manual Adjustments
```
1. ps-app-delfi runs automated calculation from FDPlan
2. Results stored in Planning Space
3. User exports results to Excel via ps-excel-agent
4. User makes manual adjustments in Excel
5. User imports adjusted data back via ps-excel-agent
6. Adjusted data used for subsequent calculations
```

---

## Technical Commonalities

### 1. .NET Framework
Both projects likely use:
- **.NET Framework** or **.NET (Core)** (ps-app-delfi uses .NET 10.0)
- **C# programming language**
- **Async/await patterns** for async operations
- **HttpClient** for API communication

### 2. HTTP Communication
Both use RESTful APIs:
- **HTTP/HTTPS** protocols
- **JSON** serialization
- **Bearer token authentication**
- **Retry mechanisms** for transient errors
- **Throttling** to respect rate limits

### 3. Error Handling
Both need robust error handling:
- **Transient error retry** with exponential backoff
- **Permanent error logging**
- **User-friendly error messages**
- **Detailed diagnostic logs**

### 4. Logging and Diagnostics
Both benefit from:
- **Structured logging** (e.g., Serilog, Microsoft.Extensions.Logging)
- **Telemetry** (potentially OpenTelemetry)
- **Performance monitoring**
- **Error tracking**

---

## Key Differences

| Aspect | ps-app-delfi | ps-excel-agent |
|--------|-------------|----------------|
| **Execution Mode** | Background service, always running | On-demand, user-initiated |
| **User Interface** | Web API (RESTful endpoints) | Excel Add-in (UI in Excel) |
| **Data Source** | FDPlan (Delfi) events | Excel workbooks |
| **Automation** | Fully automated pipeline | Manual user actions |
| **Orchestration** | Event-driven (polls FDPlan) | User-driven (button clicks) |
| **Primary Users** | System administrators, FDPlan users | Planning Space analysts, Excel users |
| **Deployment** | Server/cloud (IIS, Docker) | Client-side (Excel installation) |
| **Data Conversion** | FDPlan ↔ Planning Space formats | Excel ↔ Planning Space formats |
| **Calculation Trigger** | Automatic (on FDPlan event) | Manual (user request) or import-only |

---

## Shared Infrastructure Opportunities

### 1. Common Client Library
Potential to create a **shared NuGet package**:

**PlanningSpace.Integration.Common**
- `IPlanningSpaceService` interface
- `PlanningSpaceHttpClient` implementation
- Authentication helpers
- Retry and throttling logic
- Common data models

**Benefits:**
- Code reuse across projects
- Consistent API interaction patterns
- Centralized bug fixes and updates
- Standard error handling

**Current State:**
- ps-app-delfi has `PlanningSpace.Integration.Common` project (with `IncrementalModel`)
- ps-excel-agent could reference the same package

### 2. Shared Configuration
Both projects could use:
- **Azure Key Vault** for secrets (connection strings, API keys)
- **Shared configuration templates** for Planning Space settings
- **Common environment definitions** (Dev, UAT, Prod)

### 3. Shared Data Models
Potential to share:
- Variable data models
- Hierarchy models
- Calculation input/result models
- Economic framework models

**Implementation:**
- Extract to `PlanningSpace.Integration.Models` library
- Referenced by both projects

### 4. Shared Testing Utilities
Both projects can benefit from:
- Mock Planning Space API server
- Test data generators
- Authentication mocks
- Integration test helpers

---

## Data Format Compatibility

### Planning Space API Models
Both projects should align on:

**Variable Data Format:**
```csharp
public class GenericVariableDataModel
{
	public int HierarchyId { get; set; }
	public int ProjectId { get; set; }
	public string VariableName { get; set; }
	// Time series or scalar value
}
```

**Calculation Input:**
```csharp
public class CalculationInputModel
{
	public int HierarchyId { get; set; }
	public CalculationType CalculationType { get; set; }
	public DateTime StartDate { get; set; }
	public DateTime EndDate { get; set; }
}
```

**Calculation Result:**
```csharp
public class CalculationResultModel
{
	public int JobId { get; set; }
	public List<ProjectResultModel> ProjectResults { get; set; }
}

public class ProjectResultModel
{
	public int ProjectId { get; set; }
	public Dictionary<string, double> Indicators { get; set; } // NPV, IRR, etc.
	public Dictionary<string, List<double>> TimeSeries { get; set; }
}
```

---

## User Scenarios Involving Both Systems

### Scenario 1: Executive Dashboard
**Objective:** Create an Excel dashboard with FDPlan calculation results

**Steps:**
1. **FDPlan:** Business analyst creates multiple scenarios and triggers calculations
2. **ps-app-delfi:** Automatically processes all calculation events
3. **Planning Space:** Stores all calculation results
4. **ps-excel-agent:** Executive uses Excel add-in to pull results into a dashboard
5. **Excel:** Pivot tables, charts, and summaries created from PS data

### Scenario 2: Sensitivity Analysis
**Objective:** Test sensitivity of economic assumptions

**Steps:**
1. **Excel:** Analyst creates sensitivity table (discount rate: 5%, 10%, 15%)
2. **ps-excel-agent:** Imports each scenario to Planning Space
3. **FDPlan:** References Planning Space scenarios
4. **ps-app-delfi:** Runs calculations for each scenario
5. **ps-excel-agent:** Exports results back to Excel
6. **Excel:** Sensitivity analysis chart created

### Scenario 3: Data Quality Check
**Objective:** Verify FDPlan data before calculations

**Steps:**
1. **FDPlan:** Data entered by field engineers
2. **ps-app-delfi:** Transforms data to Planning Space format
3. **ps-excel-agent:** Exports data to Excel for review
4. **Excel:** Data quality analyst reviews and flags issues
5. **FDPlan:** Corrections made based on analysis

### Scenario 4: Historical Data Import
**Objective:** Bulk import historical data from Excel

**Steps:**
1. **Excel:** Historical production data in spreadsheet (5+ years)
2. **ps-excel-agent:** Bulk imports data to Planning Space
3. **Planning Space:** Data stored and validated
4. **FDPlan:** Creates new scenario linked to historical data
5. **ps-app-delfi:** Uses data for forecasting calculations

---

## Security and Access Control

### Authentication Alignment
Both projects should align on:

**User Roles:**
- **Administrator:** Full access to both systems
- **Analyst:** Read/write access to Planning Space data
- **Viewer:** Read-only access

**Token Management:**
- Both use JWT tokens from Planning Space
- Token expiration and refresh logic
- Secure token storage

**Data Access:**
- Both respect Planning Space permissions
- Tenant isolation (atlantis, etc.)
- Project-level access control

---

## Future Integration Opportunities

### 1. Unified Monitoring Dashboard
**Concept:** Single dashboard showing activity from both systems

**Features:**
- ps-app-delfi event processing status
- ps-excel-agent import/export logs
- Planning Space API health
- Performance metrics (calculation times, data volumes)

### 2. Shared Data Lineage
**Concept:** Track data origin and transformations

**Features:**
- Trace data from FDPlan → ps-app-delfi → Planning Space
- Trace data from Excel → ps-excel-agent → Planning Space
- Audit trail for compliance
- Data quality tracking

### 3. Cross-System Validation
**Concept:** Validate data consistency across systems

**Features:**
- Compare FDPlan source data with Planning Space stored data
- Validate Excel imports against Planning Space constraints
- Automated data quality checks
- Reconciliation reports

### 4. Orchestration Engine
**Concept:** Coordinate workflows across both systems

**Features:**
- Define multi-step workflows (FDPlan → PS → Excel)
- Trigger ps-excel-agent exports based on ps-app-delfi events
- Scheduled data synchronization
- Workflow monitoring and alerting

---

## Developer Collaboration

### Shared Knowledge Base
This knowledge repository serves both projects:
- **C:\Repos\AI Knowledge\ps_excel_agent\**
- Contains documentation for both ps-app-delfi and ps-excel-agent
- Facilitates knowledge sharing between development teams

### Code Review and Standards
Both projects should follow:
- **Common coding standards** (C# style guide)
- **Shared naming conventions** (interfaces, models)
- **Consistent logging patterns**
- **Unified testing approach**

### Dependency Management
Coordinate on:
- **NuGet package versions** (avoid conflicts)
- **Planning Space API version compatibility**
- **.NET framework versions** (align where possible)
- **Third-party library choices**

---

## Summary Table

| Aspect | ps-app-delfi | ps-excel-agent | Relationship |
|--------|-------------|----------------|--------------|
| **Data Source** | FDPlan (Delfi) | Excel workbooks | Complementary sources |
| **Target System** | Planning Space | Planning Space | **Shared target** |
| **Automation** | Automated | Manual | Different interaction models |
| **Data Flow** | FDPlan ↔ PS | Excel ↔ PS | **Both write to PS** |
| **Users** | System/FDPlan users | Excel/PS analysts | Different user groups |
| **Deployment** | Server-side | Client-side | Independent deployment |
| **Integration Pattern** | Event-driven | User-driven | Complementary triggers |
| **Authentication** | OAuth2/JWT | OAuth2/JWT (likely) | **Common auth** |
| **API Client** | Custom clients | Similar clients (expected) | **Potential shared library** |
| **Data Models** | PS models | PS models (expected) | **Potential shared models** |

---

## Conclusion

**ps-app-delfi** and **ps-excel-agent** are **complementary systems** within the PlanningSpace integration ecosystem:

1. **Shared Goal:** Enable Planning Space as the central economic calculation engine
2. **Different Approaches:** Automated (ps-app-delfi) vs. Manual (ps-excel-agent)
3. **Complementary Data Sources:** FDPlan and Excel both feed Planning Space
4. **Integration Potential:** Both read/write to Planning Space, enabling workflows spanning all three systems
5. **Code Reuse Opportunities:** Common client libraries, models, and utilities

**Key Takeaway:** While serving different purposes, both projects benefit from alignment on Planning Space API interaction, authentication patterns, and data models. The knowledge base should document commonalities to facilitate collaboration and code reuse.
