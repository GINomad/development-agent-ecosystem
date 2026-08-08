# PS-APP-DELFI: Data Flow and Event Processing Pipeline

## Project Context
**Project:** ps-app-delfi (PlanningSpace Integration Delfi Agent)  
**Purpose:** End-to-end data flow documentation for FDPlan to Planning Space integration

---

## High-Level Data Flow Overview

```
┌─────────────┐          ┌──────────────────┐          ┌──────────────────┐
│   FDPlan    │          │   Integration    │          │ Planning Space   │
│   (Delfi)   │◄────────►│      Agent       │◄────────►│                  │
└─────────────┘          └──────────────────┘          └──────────────────┘
	  │                           │                              │
	  │ 1. Event Created          │                              │
	  ├──────────────────────────►│                              │
	  │                           │ 2. Poll Events               │
	  │                           │                              │
	  │ 3. Event Details          │                              │
	  │◄──────────────────────────│                              │
	  │                           │                              │
	  │ 4. Download Input Data    │                              │
	  │◄──────────────────────────│                              │
	  │                           │                              │
	  │                           │ 5. Transform Data            │
	  │                           │                              │
	  │                           │ 6. Create Project/Hierarchy  │
	  │                           ├─────────────────────────────►│
	  │                           │                              │
	  │                           │ 7. Upload Variables          │
	  │                           ├─────────────────────────────►│
	  │                           │                              │
	  │                           │ 8. Submit Calculation        │
	  │                           ├─────────────────────────────►│
	  │                           │                              │
	  │                           │ 9. Poll Job Status           │
	  │                           │◄────────────────────────────►│
	  │                           │                              │
	  │                           │ 10. Get Results              │
	  │                           │◄─────────────────────────────│
	  │                           │                              │
	  │                           │ 11. Transform Results        │
	  │                           │                              │
	  │ 12. Upload Results        │                              │
	  │◄──────────────────────────┤                              │
	  │                           │                              │
	  │ 13. Update Event Status   │                              │
	  │◄──────────────────────────┤                              │
	  │                           │                              │
```

---

## Detailed Event Processing Steps (30 Steps)

### Phase 1: Event Discovery and Validation (Steps 1-3)

#### Step 1: Event Polling
**Component:** `EventPoller`  
**Action:** Continuously polls FDPlan for new computation events  
**Data Flow:**
```
FDPlan.IEventsController.PollEventsAsync()
	→ EventListModel
	→ EventQueueManager.Enqueue()
```

**Data Structure:**
```json
{
  "events": [
	{
	  "eventId": "event-12345",
	  "type": "COMPUTATION_REQUESTED",
	  "status": "PENDING",
	  "computationId": "comp-67890",
	  "createdAt": "2024-01-15T10:30:00Z"
	}
  ]
}
```

#### Step 2: Event Validation
**Component:** `EventProcessor`  
**Action:** Validates event structure and requirements  
**Checks:**
- Event ID present
- Computation ID valid
- Event type supported
- Not already processed

#### Step 3: Event State Management
**Component:** `Storage` (DataStore)  
**Action:** Store event in local database  
**Entities Updated:**
- `Event` entity created/updated
- Status set to "IN_PROGRESS"

---

### Phase 2: Input Data Retrieval (Steps 4-8)

#### Step 4: Fetch Computation Details
**Component:** `EventProcessor` → `IComputationController`  
**Action:** Get full computation information from FDPlan  
**Data Flow:**
```
IComputationController.GetComputationAsync(computationId)
	→ ComputationModel
```

**Data Structure:**
```json
{
  "computationId": "comp-67890",
  "studyId": "study-123",
  "scenarioId": "scenario-456",
  "workflowSpecId": "quorumsoftware:workflow-specs:planningspace-economics-demo",
  "computationSpecId": "quorumsoftware:computation-specs:planningspace-economics",
  "inputContainers": [
	{ "containerId": "container-1", "dataTypeId": "production-forecast" },
	{ "containerId": "container-2", "dataTypeId": "general-capex" },
	{ "containerId": "container-3", "dataTypeId": "general-opex" },
	{ "containerId": "container-4", "dataTypeId": "quorumsoftware:data-types:planningspace-economics-framework" }
  ]
}
```

#### Step 5: Download Input Containers
**Component:** `EventProcessor` → `IDataSourceController`  
**Action:** Download each input data container  
**Iteration:** For each container in `inputContainers`  
**Data Flow:**
```
For each container:
	IDataSourceController.DownloadContainerAsync(containerId)
		→ ContainerModel
		→ Extract files (manifest.json, data files)
```

**Container Structure:**
```json
{
  "manifest": {
	"files": [
	  { "fileName": "production-forecast.json", "dataTypeId": "production-forecast" },
	  { "fileName": "data-link.json", "dataTypeId": "planning:fdplan:data-link:1.0.0" }
	]
  },
  "files": {
	"production-forecast.json": "{ /* time series data */ }",
	"data-link.json": "{ /* metadata */ }"
  }
}
```

#### Step 6: Parse Economic Framework
**Component:** `EventProcessor` → `DataTransformer`  
**Action:** Extract and parse economic framework container  
**Special Container:** `quorumsoftware:data-types:planningspace-economics-framework`  
**Data Flow:**
```
Container files:
	econ-framework.json → EconomicFrameworkModel
	data-link.json → Metadata
```

**Economic Framework Structure:**
```json
{
  "version": "1.8",
  "hierarchyId": 12345,
  "projectId": 67890,
  "currencyDeckId": 111,
  "priceDeckId": 222,
  "variables": [
	{ "name": "DiscountRate", "value": 0.1 },
	{ "name": "TaxRate", "value": 0.25 }
  ],
  "settings": {
	"startDate": "2024-01-01",
	"endDate": "2034-12-31",
	"periodicity": "Monthly"
  }
}
```

#### Step 7: Validate Input Data
**Component:** `JsonValidator` (Conversions)  
**Action:** Validate against JSON schemas  
**Schemas:** Embedded in `PlanningSpace.Integration.Delfi.Conversions`:
- `economics-1.4.jsonc` through `economics-1.8.jsonc`
- `dataflow-2.0.jsonc` through `dataflow-2.5.jsonc`

#### Step 8: Store Input Metadata
**Component:** `Storage`  
**Action:** Record input data references  
**Database Update:**
- `DataSourceModel` entities created
- Input container IDs stored
- Timestamps recorded

---

### Phase 3: Data Transformation (Steps 9-12)

#### Step 9: Determine Target Format
**Component:** `EventProcessor`  
**Decision Logic:**
```csharp
if (eventType == EventType.EconomicsCalculation)
	targetFormat = "Economics";
else if (eventType == EventType.DataflowCalculation)
	targetFormat = "Dataflow";
```

#### Step 10: Transform Production Forecast
**Component:** `IContainerDataConverter` (for Economics) or `IDataflowDataConverter` (for Dataflow)  
**Provider:** `ContainerDataConverterProvider` or `DataflowDataConverterProvider`  
**Action:** Convert FDPlan time series to Planning Space format  

**Input (FDPlan):**
```json
{
  "timeSeries": [
	{
	  "entityId": "WELL-001",
	  "entityType": "WELL",
	  "dataType": "OIL_PRODUCTION",
	  "values": [
		{ "date": "2024-01", "value": 1000.0, "unit": "BBL/D" },
		{ "date": "2024-02", "value": 950.0, "unit": "BBL/D" }
	  ]
	}
  ]
}
```

**Output (Planning Space Economics):**
```json
{
  "variableName": "OilProduction",
  "projectId": "WELL-001",
  "timeSeries": {
	"startDate": "2024-01-01",
	"frequency": "Monthly",
	"values": [1000.0, 950.0, ...]
  }
}
```

#### Step 11: Transform CAPEX and OPEX
**Similar process as Step 10 for capital and operational expenditures**

**Input (FDPlan CAPEX):**
```json
{
  "capitalItems": [
	{
	  "entityId": "WELL-001",
	  "category": "DRILLING",
	  "timeSeries": [
		{ "date": "2024-01", "value": 5000000.0, "currency": "USD" }
	  ]
	}
  ]
}
```

**Output (Planning Space):**
```json
{
  "variableName": "DrillingCost",
  "projectId": "WELL-001",
  "timeSeries": {
	"values": [5000000.0, 0.0, ...]
  }
}
```

#### Step 12: Map Project Hierarchy
**Component:** `DataTransformer` → `FolderMappingService`  
**Action:** Map FDPlan entity hierarchy to Planning Space projects  
**Mapping Model:**
```csharp
List<ProjectsMappingModel> projectsMapping = [
	new() { 
		FDPlanEntityId = "WELL-001",
		PlanningSpaceProjectId = 12345,
		EntityType = "WELL"
	},
	new() { 
		FDPlanEntityId = "FIELD-A",
		PlanningSpaceProjectId = 12340,
		EntityType = "FIELD"
	}
];
```

---

### Phase 4: Planning Space Setup (Steps 13-17)

#### Step 13: Create/Retrieve Hierarchy
**Component:** `CalculationManager` → `IHierarchyController`  
**Decision:**
```csharp
if (economicFramework.HierarchyId > 0 && !saveResult)
{
	// Use existing hierarchy
	hierarchyId = economicFramework.HierarchyId;
}
else
{
	// Clone new hierarchy
	var cloneRequest = new CloneHierarchyModel
	{
		Name = $"FDPlan-{studyId}-{scenarioId}-{DateTime.UtcNow:yyyyMMddHHmmss}",
		ParentHierarchyId = economicFramework.HierarchyId,
		SaveResult = saveResult
	};
	hierarchyId = await _hierarchyController.CloneHierarchyAsync(cloneRequest);
}
```

#### Step 14: Create/Update Projects
**Component:** `CalculationManager` → `IProjectsController`  
**Action:** Create or update projects for each entity  
**Data Flow:**
```
For each FDPlan entity:
	IProjectsController.CreateProjectAsync(
		new AgentProjectCreationRequestModel
		{
			HierarchyId = hierarchyId,
			ProjectName = entity.Name,
			EntityType = entity.Type
		}
	) → ProjectId

	Store mapping: FDPlanEntityId ↔ ProjectId
```

#### Step 15: Upload Currency and Price Decks
**Component:** `CalculationManager` → `ICurrencyDeckController`, `IPriceDeckController`  
**Action:** Set economic assumptions  
**Data Flow:**
```
ICurrencyDeckController.SetCurrencyDeckAsync(
	hierarchyId,
	new CurrencyDeckDataModel
	{
		BaseCurrency = "USD",
		ExchangeRates = [...]
	}
)

IPriceDeckController.SetPriceDeckAsync(
	hierarchyId,
	new PriceDeckDataModel
	{
		Commodities = [
			{ Name = "Oil", PriceTimeSeries = [...] },
			{ Name = "Gas", PriceTimeSeries = [...] }
		]
	}
)
```

#### Step 16: Upload Variables
**Component:** `CalculationManager` → `IVariablesController`  
**Action:** Set all project variables  
**Bulk Upload Pattern:**
```csharp
var variableDataList = new List<GenericVariableDataModel>();

// Add scalar variables
variableDataList.Add(new ScalarVariableDataModel
{
	HierarchyId = hierarchyId,
	ProjectId = projectId,
	VariableName = "DiscountRate",
	Value = 0.1
});

// Add time series variables
variableDataList.Add(new TimeSeriesVariableDataModel
{
	HierarchyId = hierarchyId,
	ProjectId = projectId,
	VariableName = "OilProduction",
	StartDate = new DateTime(2024, 1, 1),
	Frequency = Frequency.Monthly,
	Values = [1000.0, 950.0, ...]
});

await _variablesController.BulkUploadAsync(variableDataList);
```

#### Step 17: Configure Aggregations
**Component:** `CalculationManager` → `IAggregationController`  
**Action:** Set aggregation rules for rollup calculations  
**Example:**
```json
{
  "hierarchyId": 12345,
  "aggregations": [
	{
	  "targetLevel": "FIELD",
	  "sourceLevel": "WELL",
	  "operator": "SUM",
	  "variables": ["OilProduction", "GasProduction"]
	}
  ]
}
```

---

### Phase 5: Calculation Execution (Steps 18-22)

#### Step 18: Submit Calculation Job
**Component:** `CalculationManager` → `ICalculationController`  
**Action:** Initiate calculation in Planning Space  
**Data Flow:**
```
ICalculationController.SubmitCalculationAsync(
	new CalculationInputModel
	{
		HierarchyId = hierarchyId,
		CalculationType = CalculationType.Economics,
		Parameters = new CalculationParameters
		{
			StartDate = startDate,
			EndDate = endDate,
			UseDistributedProcessing = true
		}
	}
) → JobId
```

**Response:**
```json
{
  "jobId": "job-98765",
  "status": "Queued",
  "submittedAt": "2024-01-15T10:45:00Z"
}
```

#### Step 19: Poll Job Status
**Component:** `CalculationManager` → `IJobController`  
**Action:** Continuously check job progress  
**Polling Logic:**
```csharp
var pollingInterval = TimeSpan.FromSeconds(config["PlanningSpace:CalculationJobs:PollingIntervalInSeconds"]);
var timeout = TimeSpan.FromSeconds(config["PlanningSpace:CalculationJobs:TimeOutInSeconds"]);
var startTime = DateTime.UtcNow;

while (DateTime.UtcNow - startTime < timeout)
{
	var jobStatus = await _jobController.GetJobStatusAsync(jobId);

	if (jobStatus.Status == JobStatus.Completed)
		break;
	else if (jobStatus.Status == JobStatus.Failed)
		throw new CalculationFailedException(jobStatus.ErrorMessage);

	await Task.Delay(pollingInterval);
}
```

**Job Status Response:**
```json
{
  "jobId": "job-98765",
  "status": "Running",
  "progress": 65,
  "startedAt": "2024-01-15T10:45:05Z",
  "logs": [
	{ "timestamp": "2024-01-15T10:45:10Z", "level": "Info", "message": "Processing project WELL-001..." }
  ]
}
```

#### Step 20: Retrieve Calculation Logs
**Component:** `CalculationLogService`  
**Action:** Download and store calculation logs  
**Data Flow:**
```
IJobController.GetJobLogsAsync(jobId)
	→ JobLogModel
	→ CalculationLog entity (database)
	→ Optional: Write to file system
```

#### Step 21: Handle Calculation Errors
**Component:** `CalculationManager`  
**Action:** Process calculation failures  
**Error Handling:**
```csharp
if (jobStatus.Status == JobStatus.Failed)
{
	_logger.LogError("Calculation failed: {ErrorMessage}", jobStatus.ErrorMessage);

	await _storage.UpdateEventStatusAsync(eventId, EventStatus.Failed, jobStatus.ErrorMessage);

	// Notify FDPlan of failure
	await _computationController.UpdateComputationStatusAsync(
		computationId,
		ComputationStatus.Failed,
		jobStatus.ErrorMessage
	);

	return;
}
```

#### Step 22: Verify Calculation Success
**Component:** `CalculationManager`  
**Action:** Validate calculation completed without warnings/errors

---

### Phase 6: Results Retrieval (Steps 23-25)

#### Step 23: Download Results
**Component:** `CalculationManager` → `ICalculationController`  
**Action:** Retrieve calculation results from Planning Space  
**Data Flow:**
```
ICalculationController.GetCalculationResultsAsync(jobId)
	→ CalculationResultModel
```

**Result Structure:**
```json
{
  "jobId": "job-98765",
  "hierarchyId": 12345,
  "results": {
	"projects": [
	  {
		"projectId": 12345,
		"projectName": "WELL-001",
		"indicators": [
		  {
			"name": "NPV",
			"value": 15000000.0,
			"unit": "USD"
		  },
		  {
			"name": "IRR",
			"value": 0.18,
			"unit": "PERCENTAGE"
		  },
		  {
			"name": "PaybackPeriod",
			"value": 4.5,
			"unit": "YEARS"
		  }
		],
		"timeSeries": [
		  {
			"variableName": "NetCashFlow",
			"values": [
			  { "date": "2024-01", "value": -5000000.0 },
			  { "date": "2024-02", "value": 800000.0 }
			]
		  }
		]
	  }
	]
  }
}
```

#### Step 24: Parse Results
**Component:** `EventProcessor`  
**Action:** Extract economic indicators and time series

#### Step 25: Store Results Locally
**Component:** `Storage`  
**Action:** Cache results in local database  
**Database Update:**
- `CalculationLog` entity updated with results
- Metadata stored for audit trail

---

### Phase 7: Results Upload to FDPlan (Steps 26-28)

#### Step 26: Transform Results to FDPlan Format
**Component:** `CalculationResultConverter` (Conversions)  
**Action:** Convert Planning Space results to FDPlan economic-results format  

**Planning Space Output:**
```json
{
  "projectId": 12345,
  "indicators": [
	{ "name": "NPV", "value": 15000000.0 }
  ]
}
```

**FDPlan Format:**
```json
{
  "resultSet": {
	"entityId": "WELL-001",
	"entityType": "WELL",
	"indicators": [
	  {
		"indicatorType": "NPV",
		"value": 15000000.0,
		"currency": "USD"
	  }
	]
  }
}
```

#### Step 27: Create Result Container
**Component:** `EventProcessor` → `IComputationController`  
**Action:** Package results for FDPlan  
**Data Flow:**
```
Create ContainerManifest:
	- File: economic-results.json
	- DataTypeId: "economic-results"

IComputationController.UploadResultsAsync(
	computationId,
	new ResultContainerModel
	{
		Manifest = manifest,
		Files = { "economic-results.json": resultsJson }
	}
)
```

#### Step 28: Upload Results
**Component:** `EventProcessor` → `IComputationController`  
**Action:** Send results to FDPlan

---

### Phase 8: Event Completion (Steps 29-30)

#### Step 29: Update Event Status in FDPlan
**Component:** `EventProcessor` → `IEventsController`  
**Action:** Mark event as completed  
**Data Flow:**
```
IEventsController.UpdateEventStatusAsync(
	eventId,
	new EventStatusUpdateModel
	{
		Status = EventStatus.Completed,
		CompletedAt = DateTime.UtcNow,
		ResultContainerId = resultContainerId
	}
)
```

#### Step 30: Cleanup (Optional)
**Component:** `EventProcessor`  
**Actions:**
- Delete temporary hierarchy (if `saveResult = false`)
- Archive calculation logs to file system
- Remove temporary data from database
- Update event status locally

**Cleanup Logic:**
```csharp
if (!saveResult && hierarchyId > 0)
{
	await _hierarchyController.DeleteHierarchyAsync(hierarchyId);
}

if (config["PlanningSpace:CalculationJobs:LogToFiles:Enabled"])
{
	var logPath = Path.Combine(
		config["PlanningSpace:CalculationJobs:LogToFiles:RootFolder"],
		$"calculation-{eventId}.log"
	);
	await File.WriteAllTextAsync(logPath, calculationLogs);
}

await _storage.UpdateEventStatusAsync(eventId, EventStatus.Completed);
```

---

## Dataflow Processing (Alternative Path)

### Dataflow Event Processing
For `EventType.DataflowImport` or `EventType.DataflowExport`:

#### Import Flow
```
1. Poll Dataflow events from FDPlan
2. Download Dataflow container (dataflow-2.x format)
3. Parse DataflowVariableModel list
4. Transform to Planning Space Dataflow format
5. Upload to Planning Space via IVariableDataController
6. Update event status
```

#### Export Flow
```
1. Receive export request event
2. Download data from Planning Space Dataflow
3. Convert to FDPlan dataflow-2.x format
4. Create result container
5. Upload to FDPlan
6. Update event status
```

---

## Error Handling and Retry Logic

### Transient Error Handling
**Component:** Network throttling and retry mechanisms  
**Configuration:**
```json
{
  "PlanningSpace": {
	"NetworkRequests": {
	  "TransientErrorStatusCodes": [408, 429, 500, 502, 503, 504],
	  "NumberOfAttempts": 3,
	  "RetryIntervalInSeconds": 5,
	  "BackOffFactor": 2.0
	}
  }
}
```

**Retry Logic:**
```csharp
for (int attempt = 1; attempt <= maxAttempts; attempt++)
{
	try
	{
		return await operation();
	}
	catch (HttpRequestException ex) when (IsTransientError(ex))
	{
		if (attempt < maxAttempts)
		{
			var delay = retryInterval * Math.Pow(backOffFactor, attempt - 1);
			await Task.Delay(TimeSpan.FromSeconds(delay));
		}
		else
		{
			throw;
		}
	}
}
```

### Backlog Task Retry
**Component:** `BackgroundTaskManager`  
**Purpose:** Retry failed cleanup tasks  
**Tasks:**
- Deleting temporary hierarchies
- Updating FDPlan event status
- Uploading results

**Configuration:**
```json
{
  "PlanningSpace": {
	"BacklogTasks": {
	  "RetryIntervalInMinutes": 5,
	  "RetryDurationInHours": 24
	}
  }
}
```

---

## Data Persistence

### Database Schema
**Tables:**
- `Events` - Event tracking
- `CalculationLogs` - Calculation history
- `Configurations` - Integration configurations
- `DataSourceModels` - Data source metadata
- `RegisterConfigurationSets` - Register sync config
- `RegisterSyncLogs` - Sync history
- `Settings` - Runtime settings
- `BacklogTasks` - Failed tasks for retry

### Event State Transitions
```
DISCOVERED → QUEUED → IN_PROGRESS → COMPLETED
				  ↓
				FAILED ← (can retry) → RETRYING
				  ↓
				ARCHIVED
```

---

## Performance Considerations

### Throttling
**Component:** `PlanningSpaceNetworkThrottler`, `FDPlanNetworkThrottler`  
**Purpose:** Prevent API rate limit violations  
**Configuration:**
```json
{
  "PlanningSpace": {
	"Throttling": {
	  "MaxRequestsPerSecond": 100,
	  "DegradedModeRateFactor": 0.5
	}
  }
}
```

**Behavior:**
- Track requests per second
- Delay requests exceeding limit
- Reduce rate on 429 responses (degraded mode)
- Recover gradually

### Parallel Processing
**Component:** `EventQueueManager`  
**Capability:** Process multiple events concurrently  
**Configuration:** Configurable max concurrent events

### Bulk Operations
- Bulk variable uploads reduce API calls
- Batch data transformations
- Streaming for large datasets

---

## Summary

**Data Flow Stages:**
1. **Event Discovery** - Poll FDPlan for events
2. **Input Retrieval** - Download computation inputs
3. **Data Transformation** - Convert FDPlan ↔ Planning Space formats
4. **PS Setup** - Create hierarchies, projects, upload data
5. **Calculation** - Execute and monitor jobs
6. **Results Retrieval** - Download calculation results
7. **Results Upload** - Send results back to FDPlan
8. **Completion** - Update statuses and cleanup

**Key Data Formats:**
- FDPlan: JSON containers with manifests
- Planning Space: RESTful API models
- Economic formats: 1.4 through 1.8
- Dataflow formats: 2.0 through 2.5

**Integration Points:**
- 35+ API controllers
- Multiple data converters
- Comprehensive error handling
- Retry and throttling mechanisms
- Full audit trail in database
