# PS-APP-DELFI: API Contracts and Interfaces

## Project Context
**Project:** ps-app-delfi (PlanningSpace Integration Delfi Agent)  
**Purpose:** Interface definitions and contracts for integration between FDPlan and Planning Space

---

## Core Service Interfaces

### 1. IFDPlanService
**Location:** `PlanningSpace.Integration.Delfi.DelfiClient\IFDPlanService.cs`  
**Purpose:** Base service interface for FDPlan HTTP client operations  
**Extends:** `INetworkClientService` (from Utilities)

```csharp
public interface IFDPlanService : INetworkClientService
{
	// Network client service methods inherited
}
```

**Usage:** Base marker interface for all FDPlan API controllers

---

### 2. IPlanningSpaceService
**Location:** `PlanningSpace.Integration.Delfi.PlanningSpaceClient\IPlanningSpaceService.cs`  
**Purpose:** Base service interface for Planning Space HTTP client operations  
**Extends:** `INetworkClientService`

```csharp
public interface IPlanningSpaceService : INetworkClientService
{
	string GetAuthKey();
	string GetTenantUrl();
	string GetAccessToken();

	/// <summary>
	/// Exchanges the supplied user bearer token for a delegated token 
	/// the agent can use for long-running background calls.
	/// Returns null if exchange is not configured.
	/// </summary>
	Task<string> ExchangeTokenAsync(string userBearerToken);
}
```

**Key Methods:**
- `GetAuthKey()` - Retrieves API authentication key
- `GetTenantUrl()` - Gets tenant-specific URL
- `GetAccessToken()` - Retrieves current access token
- `ExchangeTokenAsync(userBearerToken)` - Token delegation for background operations

---

### 3. IDataConverter
**Location:** `PlanningSpace.Integration.Delfi.Agent\IDataConverter.cs`  
**Purpose:** Converts data between FDPlan and Dataflow formats

```csharp
public interface IDataConverter
{
	/// <summary>
	/// Converts FDPlan result set data to Dataflow variable data format.
	/// </summary>
	Task<List<DataflowVariableDataModel>> GetVariableData(
		ResultSetModel data, 
		string fileName, 
		string dataTypeId,
		int scenarioId, 
		int versionId, 
		string configurationId, 
		List<ProjectsMappingModel> projectsMapping);
}
```

**Key Responsibilities:**
- Transform FDPlan ResultSetModel to Dataflow format
- Map projects between systems
- Handle scenario and version mapping

---

## FDPlan Client Controllers

### 4. IComputationController
**Location:** `PlanningSpace.Integration.Delfi.DelfiClient\IComputationController.cs`  
**Purpose:** Manage FDPlan computations

**Key Operations:**
- Get computation details
- List computations
- Create computation
- Update computation status
- Get computation results
- Get computation logs

---

### 5. IEventsController
**Location:** `PlanningSpace.Integration.Delfi.DelfiClient\IEventsController.cs`  
**Purpose:** Poll and manage FDPlan events

**Key Operations:**
- Poll for new events (main integration trigger)
- Get event details
- Update event status
- Post-process events

---

### 6. IDataSourceController
**Location:** `PlanningSpace.Integration.Delfi.DelfiClient\IDataSourceController.cs`  
**Purpose:** Manage data sources in FDPlan

**Key Operations:**
- List data sources
- Get data source details
- Create/update data sources
- Download data source content

---

### 7. IComputationSpecsController, IWorkflowSpecsController
**Purpose:** Manage computation and workflow specifications
- Get/create computation specs
- Get/create workflow specs
- Define input/output data types

---

### 8. IDataTypesController, IDataSourceTypesController
**Purpose:** Manage data type definitions
- Register custom data types
- Configure data source types
- Define file specifications

---

### 9. IScenarioController, IStudyController
**Purpose:** Manage FDPlan studies and scenarios
- List studies and scenarios
- Get scenario details
- Create/update scenarios

---

### 10. IRegisterOpportunityController
**Purpose:** Manage opportunity registers
- Get opportunity data
- Update opportunity information
- Sync opportunity registers

---

## Planning Space Client Controllers

### 11. ICalculationController
**Location:** `PlanningSpace.Integration.CalculationOrchestrator\ICalculationController.cs`  
**Purpose:** Orchestrate Planning Space calculations

**Key Operations:**
- Submit calculation jobs
- Monitor job progress
- Retrieve calculation results
- Clone hierarchies for calculations
- Manage calculation parameters

**Critical Methods:**
- `CloneHierarchyAsync()` - Create calculation hierarchy
- `SubmitCalculationAsync()` - Start calculation job
- `GetCalculationStatusAsync()` - Poll job status
- `GetCalculationResultsAsync()` - Retrieve results

---

### 12. IProjectsController
**Location:** `PlanningSpace.Integration.CalculationOrchestrator\IProjectsController.cs`  
**Purpose:** Manage Planning Space projects

**Key Operations:**
- Create agent projects
- Update project properties
- Patch project data
- Configure working interest partners

---

### 13. IVariablesController (Economics)
**Location:** `PlanningSpace.Integration.CalculationOrchestrator\IVariablesController.cs`  
**Purpose:** Manage economic variables

**Key Operations:**
- Get/set scalar variables
- Get/set time series variables
- Bulk update variables
- Configure variable metadata

---

### 14. IHierarchyController
**Purpose:** Manage Planning Space hierarchies
- Create/clone hierarchies
- Update hierarchy structure
- Delete hierarchies

---

### 15. ICurrencyDeckController, IPriceDeckController
**Purpose:** Manage economic assumptions
- Get/set currency decks
- Get/set price decks
- Configure deck data

---

### 16. IAggregationController
**Purpose:** Manage aggregation rules
- Define aggregation logic
- Configure rollup rules

---

### 17. IBulkDataController
**Purpose:** Bulk data operations
- Upload large datasets
- Download bulk data
- Optimize data transfer

---

## Dataflow Client Controllers

### 18. IVariablesController (Dataflow)
**Location:** `PlanningSpace.Integration.Delfi.DataflowClient\IVariablesController.cs`  
**Purpose:** Manage Dataflow variables (distinct from Economics variables)

**Key Operations:**
- List Dataflow variables
- Get variable metadata
- Create/update Dataflow variables

---

### 19. IVariableDataController
**Purpose:** Manage Dataflow variable data
- Upload variable data
- Download variable data
- Update time series data

---

### 20. IHierarchyDocumentsController
**Purpose:** Manage Dataflow hierarchy documents
- Get hierarchy document metadata
- Update hierarchy documents

---

### 21. IAggregationDataController
**Purpose:** Manage aggregation data in Dataflow
- Get aggregation data
- Update aggregation data

---

### 22. IDocumentSettingsController, IPresetsController
**Purpose:** Dataflow configuration
- Manage document settings
- Handle preset configurations

---

## Data Conversion Interfaces

### 23. IContainerDataConverter
**Location:** `PlanningSpace.Integration.Delfi.Conversions\FDPlanToEconomicsConverters\IContainerDataConverter.cs`  
**Purpose:** Convert container data from FDPlan to Economics format

**Responsibilities:**
- Parse container manifests
- Transform data structures
- Map data types

---

### 24. IContainerDataConverterProvider
**Purpose:** Factory for container data converters
- Provide appropriate converter based on data type
- Support multiple version formats

---

### 25. IDataflowDataConverter, IDataflowDataConverterProvider
**Location:** `PlanningSpace.Integration.Delfi.Conversions\DataflowToFDPlanConverters\`  
**Purpose:** Convert between Dataflow and FDPlan formats

**Key Implementations:**
- EventSchemaConverter
- ResultSchemaConverter
- OpportunityRegisterConverter

---

### 26. IOpportunityRegisterConverter
**Purpose:** Convert opportunity register data
- Parse FDPlan opportunity lists
- Transform to Dataflow format
- Handle field mappings

---

## Agent Helper Interfaces

### 27. IDataSourceHelper
**Location:** `PlanningSpace.Integration.Delfi.Agent\V1\Helpers\IDataSourceHelper.cs`  
**Purpose:** Helper for data source operations

---

### 28. IOpportunitiesHelper
**Purpose:** Helper for opportunity data operations

---

### 29. IRegisterHelper
**Purpose:** Helper for register management operations

---

## Utility Interfaces

### 30. ISpecInitializer
**Location:** `PlanningSpace.Integration.Delfi.Agent\ISpecInitializer.cs`  
**Purpose:** Initialize computation and workflow specs in FDPlan
- Bootstrap data types
- Register computation specs
- Configure workflow specs

---

### 31. IRegisterSyncScheduler
**Location:** `PlanningSpace.Integration.Delfi.Agent\IRegisterSyncScheduler.cs`  
**Purpose:** Schedule register synchronization tasks
- Manage sync schedules
- Trigger periodic syncs

---

### 32. IIntegrationMonitor
**Location:** `PlanningSpace.Integration.Delfi.Agent\IIntegrationMonitor.cs`  
**Purpose:** Monitor integration health and metrics
- Track processing metrics
- Monitor system health
- Collect performance data

---

## Job Controllers

### 33. IJobController
**Location:** `PlanningSpace.Integration.Delfi.PlanningSpaceClient\IJobController.cs`  
**Purpose:** Manage Planning Space background jobs
- Submit jobs
- Poll job status
- Cancel jobs
- Retrieve job logs

---

## Database Settings Interfaces

### 34. IDatabaseSettingsProvider
**Location:** `PlanningSpace.Integration.Delfi.DataStore\Settings\IDatabaseSettingsProvider.cs`  
**Purpose:** Provide runtime settings from database
- Get configuration values
- Update settings dynamically
- Support hierarchical configuration

---

## Version Controllers

### 35. IVersionController
**Location:** `PlanningSpace.Integration.CalculationOrchestrator\IVersionController.cs`  
**Purpose:** Retrieve Planning Space version information
- Get API version
- Check compatibility

---

## Key Data Models (Contracts)

### FDPlan Models (`PlanningSpace.Integration.Delfi.DelfiClient.Models`)
- `ComputationModel` - Computation definition
- `EventModel` - Event data
- `ContainerModel` - Data container
- `ResultSetModel` - Calculation results
- `TimeSerieModel` - Time series data
- `EconomicFrameworkModel` - Economic assumptions
- `DataflowFrameworkModel` - Dataflow structure

### Planning Space Models (`PlanningSpace.Integration.CalculationOrchestrator.Models`)
- `CalculationInputModel` - Calculation input
- `CalculationResultModel` - Calculation output
- `HierarchyModel` - Hierarchy definition
- `ProjectPatchModel` - Project updates
- `CurrencyDeckModel`, `PriceDeckModel` - Economic decks
- `GenericVariableDataModel` - Variable data

### Dataflow Models (`PlanningSpace.Integration.Delfi.DataflowClient.Models`)
- `DataflowVariableModel` - Dataflow variable definition
- `DataflowVariableDataModel` - Variable data
- `AggregationDataModel` - Aggregation data
- `DocumentSettingsModel` - Document configuration

### Conversion Models (`PlanningSpace.Integration.Delfi.Conversions.Models`)
- `EconomicsMappingModel` - Economics field mappings
- `DataflowMappingModel` - Dataflow field mappings
- `ProjectsMappingModel` - Project mappings

---

## Contract Principles

### Design Patterns
1. **Interface Segregation** - Focused, single-purpose interfaces
2. **Dependency Inversion** - Depend on abstractions, not implementations
3. **Factory Pattern** - Provider interfaces for converters
4. **Strategy Pattern** - Converter interfaces for different formats

### Naming Conventions
- Interface names start with `I`
- Controller interfaces end with `Controller`
- Service interfaces end with `Service`
- Helper interfaces end with `Helper`
- Converter interfaces end with `Converter`
- Provider interfaces end with `Provider`

### Common Patterns
- All controllers inherit from base service interfaces
- Async operations return `Task` or `Task<T>`
- Models use suffix `Model` (e.g., `EventModel`)
- Exception handling at controller level
- Logging via dependency injection

### API Versioning
- Controllers organized in `V1` namespace
- Future versions can be added (V2, V3, etc.)
- Maintains backward compatibility

---

## Integration Contract Flow

```
FDPlan Event → IEventsController.PollEvents()
	↓
IComputationController.GetComputation()
	↓
IDataSourceController.DownloadContent()
	↓
IContainerDataConverter.Convert()
	↓
IProjectsController.CreateProject()
IVariablesController.SetVariables()
	↓
ICalculationController.SubmitCalculation()
	↓
IJobController.PollJobStatus()
	↓
ICalculationController.GetResults()
	↓
ResultSchemaConverter.Convert()
	↓
IComputationController.UploadResults()
	↓
IEventsController.UpdateEventStatus()
```

---

## Contract Extensibility

### Adding New Data Types
1. Create new models in appropriate namespace
2. Implement `IContainerDataConverter` or `IDataflowDataConverter`
3. Register in provider factory
4. Update conversion logic

### Adding New Endpoints
1. Define interface extending base service interface
2. Implement concrete controller
3. Register in DI container
4. Add to API routing

### Version Migration
- Converters support multiple format versions
- File formats versioned (economics-1.4 through 1.8, dataflow-2.0 through 2.5)
- Schema validation ensures compatibility
