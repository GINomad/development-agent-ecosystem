# PS-APP-DELFI: Code Style and Conventions

## Project Context
**Project:** ps-app-delfi (PlanningSpace Integration Delfi Agent)  
**Framework:** .NET 10.0  
**Language:** C# 12 with implicit usings enabled

---

## General C# Style

### File Organization
1. **Namespace Declaration:** File-scoped namespaces (C# 10+)
2. **Using Directives:** At the top of each file
3. **Class/Interface per File:** One primary type per file
4. **File Naming:** Matches the primary type name (e.g., `EventProcessor.cs`)

### Example Structure
```csharp
using Microsoft.Extensions.Logging;
using PlanningSpace.Integration.Delfi.DataStore;
using System.Text.Json;

namespace PlanningSpace.Integration.Delfi.Agent
{
	/// <summary>
	/// Orchestrates the complete processing of a single event.
	/// </summary>
	public class EventProcessor
	{
		private readonly ILogger _logger;

		public EventProcessor(ILogger logger)
		{
			_logger = logger;
		}
	}
}
```

---

## Naming Conventions

### Interfaces
- Start with `I` prefix
- PascalCase naming
- Examples: `IDataConverter`, `IFDPlanService`, `IEventProcessor`

### Classes
- PascalCase naming
- Descriptive names indicating purpose
- Examples: `EventProcessor`, `CalculationManager`, `DataConverter`

### Methods
- PascalCase naming
- Async methods end with `Async` suffix
- Examples: `ProcessEvent()`, `GetDataAsync()`, `CloneHierarchyAsync()`

### Parameters and Local Variables
- camelCase naming
- Descriptive, full words (avoid abbreviations unless standard)
- Examples: `eventId`, `calculationResult`, `hierarchyName`

### Private Fields
- Prefix with underscore `_`
- camelCase naming
- Examples: `_logger`, `_config`, `_storage`

### Constants
- PascalCase or UPPER_CASE (context-dependent)
- Constants in Program.cs use lowercase with underscore: `_serviceName`, `_version`
- Class-level constants: `DefaultConsolidatedEntityType`, `OpportunityEntityType`

### Properties
- PascalCase naming
- Auto-properties preferred when no logic needed
- Examples: `EventId`, `Configuration`, `BaseUrl`

---

## Code Structure Patterns

### Dependency Injection
**All services use constructor injection:**

```csharp
public class EventProcessor
{
	private readonly IConfiguration _config;
	private readonly IComputationController _computationController;
	private readonly ICalculationController _calculationController;
	private readonly Storage _storage;
	private readonly ILogger _logger;

	public EventProcessor(
		IConfiguration config,
		IComputationController computationController,
		ICalculationController calculationController,
		Storage storage,
		ILogger logger)
	{
		_config = config;
		_computationController = computationController;
		_calculationController = calculationController;
		_storage = storage;
		_logger = logger;
	}
}
```

**Pattern:**
- All dependencies as readonly fields
- Underscore prefix for private fields
- Constructor assigns dependencies
- No service locator anti-pattern

---

### Async/Await Patterns

**Standard async method:**
```csharp
public async Task<int> CloneHierarchy(
	string eventId,
	int currentHierarchyId,
	bool useAdvancedCalculationAPI,
	bool saveResult,
	string hierarchyName,
	string studyId,
	string scenarioId,
	Action<string> logText)
{
	logText($"Cloning hierarchy for event {eventId}...");
	var result = await _calculationController.CloneHierarchyAsync(
		new CloneHierarchyModel
		{
			Name = hierarchyName,
			SaveResult = saveResult
		});
	return result.HierarchyId;
}
```

**Conventions:**
- All async methods return `Task` or `Task<T>`
- Use `await` instead of `.Result` or `.Wait()`
- Configure await only when necessary (not default)
- Exception propagation automatic through async

---

### Error Handling

**Standard try-catch pattern:**
```csharp
try
{
	await CreateHostBuilder(args).Build().RunAsync();
}
catch (TaskCanceledException)
{
	// Expected when Ctrl+C is pressed during startup
}
```

**Conventions:**
- Catch specific exceptions when possible
- Log exceptions at appropriate level
- Re-throw when not handled
- Use exception filters for specific handling
- Document expected exceptions

---

## XML Documentation

### Required for Public APIs
All public classes, methods, and properties have XML comments:

```csharp
/// <summary>
/// Orchestrates the complete processing of a single event through all 30 steps.
/// Coordinates all other services to complete the end-to-end event processing workflow.
/// </summary>
public class EventProcessor
{
	/// <summary>
	/// Callback to notify when event is no longer in progress.
	/// </summary>
	public Action<string> EventNoLongerInProgressCallback { get; set; }

	/// <summary>
	/// Clones a hierarchy in Planning Space if needed for the calculation.
	/// </summary>
	/// <param name="eventId">The event ID for logging purposes.</param>
	/// <param name="currentHierarchyId">The current hierarchy ID, if already cloned.</param>
	/// <param name="useAdvancedCalculationAPI">Whether to use the advanced calculation API.</param>
	/// <returns>The hierarchy ID.</returns>
	public async Task<int> CloneHierarchy(
		string eventId,
		int currentHierarchyId,
		bool useAdvancedCalculationAPI,
		...
	)
	{
		// Implementation
	}
}
```

**XML Doc Standards:**
- `<summary>` for all public types and members
- `<param>` for all method parameters
- `<returns>` for return values
- `<remarks>` for additional details
- `<exception>` for thrown exceptions

---

## Project Structure Conventions

### Folder Organization
```
PlanningSpace.Integration.Delfi.Agent/
├── V1/
│   ├── Controllers/          # API controllers
│   └── Helpers/              # Controller helpers
├── Bootstrap/                # DI and startup helpers
├── Data/                     # Static data files
├── Properties/               # Assembly properties
├── Program.cs                # Entry point
├── Startup.cs                # Service configuration
└── (Service classes)         # Core services
```

### Namespace Alignment
- Namespace matches folder structure
- Example: `PlanningSpace.Integration.Delfi.Agent.V1.Controllers`

---

## Configuration Style

### appsettings.json Structure
```json
{
  "KeyVault": {
	"Url": "https://...",
	"SecretName": "..."
  },
  "PlanningSpace": {
	"BaseUrl": "https://...",
	"Tenant": "atlantis",
	"NetworkRequests": {
	  "EnableContentCompression": true,
	  "TimeoutInSeconds": 0
	}
  }
}
```

**Conventions:**
- PascalCase keys
- Hierarchical structure
- Defaults in `appsettings.Defaults.json`
- Secrets in Azure Key Vault, not in files

---

## Entity Framework Conventions

### DbContext
```csharp
public class DataStoreDbContext : DbContext
{
	public DbSet<Event> Events { get; set; }
	public DbSet<CalculationLog> CalculationLogs { get; set; }
	public DbSet<Configuration> Configurations { get; set; }
}
```

### Entity Classes
```csharp
public class Event
{
	[Key]
	public string EventId { get; set; }

	public DateTime CreatedAt { get; set; }
	public EventType Type { get; set; }

	[ForeignKey(nameof(Configuration))]
	public string ConfigurationId { get; set; }

	public virtual Configuration Configuration { get; set; }
}
```

**Conventions:**
- Entity classes in `Entities/` folder
- Data annotations for configuration
- Virtual navigation properties for lazy loading
- Explicit foreign key properties

---

## Service Registration Style

### Startup.cs Pattern
```csharp
public void ConfigureServices(IServiceCollection services)
{
	// Framework services
	services.AddMvc(options => options.EnableEndpointRouting = false);
	services.AddSwaggerGen(c => { /* config */ });
	services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme);

	// HTTP clients
	services.AddHttpClient("PlanningSpace");
	services.AddHttpClient("FDPlan");

	// Application services
	services.AddSingleton<EventQueueManager>();
	services.AddScoped<EventProcessor>();
	services.AddScoped<CalculationManager>();

	// Background services
	services.AddHostedService<IntegrationMonitorHostedService>();
}
```

**Conventions:**
- Group related registrations
- Comment sections for clarity
- Singleton for stateful services
- Scoped for per-request services
- Transient for stateless utilities

---

## Controller Style

### API Controller Pattern
```csharp
[ApiController]
[Route("api/v{version:apiVersion}/[controller]")]
[Authorize]
public class ConfigurationController : ControllerBase
{
	private readonly Storage _storage;
	private readonly ILogger<ConfigurationController> _logger;

	public ConfigurationController(Storage storage, ILogger<ConfigurationController> logger)
	{
		_storage = storage;
		_logger = logger;
	}

	[HttpGet]
	[ProducesResponseType(typeof(List<Configuration>), StatusCodes.Status200OK)]
	public async Task<IActionResult> GetConfigurations()
	{
		var configurations = await _storage.GetConfigurationsAsync();
		return Ok(configurations);
	}
}
```

**Conventions:**
- Inherit from `ControllerBase` (not `Controller` for APIs)
- Use attribute routing
- Authorize by default, opt-out where needed
- Return `IActionResult` or `ActionResult<T>`
- Use `ProducesResponseType` for Swagger documentation

---

## Logging Style

### Structured Logging
```csharp
_logger.LogInformation("Processing event {EventId} for study {StudyId}", eventId, studyId);
_logger.LogWarning("Calculation timeout for event {EventId} after {TimeoutSeconds}s", eventId, timeout);
_logger.LogError(ex, "Failed to process event {EventId}", eventId);
```

**Conventions:**
- Use structured logging with placeholders
- Parameters in braces: `{ParameterName}`
- Include relevant context in log messages
- Log exceptions with `LogError(exception, message)`
- Use appropriate log levels (Trace, Debug, Information, Warning, Error, Critical)

---

## Testing Style

### Test Class Naming
```csharp
[TestClass]
public class EventProcessorTests
{
	[TestMethod]
	public async Task ProcessEvent_ValidEvent_CompletesSuccessfully()
	{
		// Arrange
		var mockController = new Mock<IComputationController>();
		var processor = new EventProcessor(mockController.Object);

		// Act
		var result = await processor.ProcessEventAsync("event-123");

		// Assert
		Assert.IsTrue(result.Success);
	}
}
```

**Conventions:**
- Test class name = `{ClassName}Tests`
- Test method pattern: `MethodName_Scenario_ExpectedResult`
- Arrange-Act-Assert structure
- Use MSTest attributes: `[TestClass]`, `[TestMethod]`
- Mock dependencies with Moq

---

## Common Abbreviations (Accepted)

- **API** - Application Programming Interface
- **HTTP** - Hypertext Transfer Protocol
- **JSON** - JavaScript Object Notation
- **SQL** - Structured Query Language
- **CAPEX** - Capital Expenditure
- **OPEX** - Operational Expenditure
- **FD** - Field Development
- **PS** - Planning Space
- **DF** - Dataflow

---

## Anti-Patterns to Avoid

### ❌ Don't Use
- `var` when type is not obvious from right side
- `.Result` or `.Wait()` on async operations (use `await`)
- Magic numbers (use named constants)
- Regions (`#region`) for code organization
- Deep nesting (refactor to reduce complexity)
- Commented-out code (remove or justify)
- Hungarian notation (`strName`, `intCount`)

### ✅ Do Use
- Explicit types when clarity needed
- `async`/`await` for all async operations
- Named constants or configuration
- Proper classes/methods for organization
- Early returns to reduce nesting
- Version control for code history
- Descriptive names

---

## Code Comments Style

### When to Comment
- Complex algorithms
- Non-obvious business logic
- Workarounds for known issues
- Performance optimizations
- TODO notes with issue tracking numbers

### Example
```csharp
// Retry with exponential backoff to handle transient network errors
// This ensures we don't overwhelm the API during recovery periods
for (int attempt = 1; attempt <= maxAttempts; attempt++)
{
	try
	{
		return await operation();
	}
	catch (HttpRequestException ex) when (IsTransientError(ex))
	{
		await Task.Delay(delay * attempt);
	}
}
```

---

## OpenTelemetry / Observability Style

### Instrumentation Pattern
```csharp
using var activity = _activitySource.StartActivity("ProcessEvent");
activity?.SetTag("event.id", eventId);
activity?.SetTag("study.id", studyId);

try
{
	// Operation
	activity?.SetStatus(ActivityStatusCode.Ok);
}
catch (Exception ex)
{
	activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
	throw;
}
```

**Conventions:**
- Use activity source for distributed tracing
- Tag activities with relevant context
- Set success/failure status
- Use meters for metrics
- Structured logging correlates with traces

---

## Resource Management

### Dispose Pattern
```csharp
using var httpClient = _httpClientFactory.CreateClient("PlanningSpace");
using var response = await httpClient.GetAsync(url);
// Automatic disposal
```

**Conventions:**
- Use `using` statements for disposables
- Prefer `using var` declaration (C# 8+)
- Explicit disposal for long-lived resources
- Implement `IDisposable` when managing unmanaged resources

---

## JSON Handling Style

### Serialization Configuration
```csharp
var options = new JsonSerializerOptions
{
	PropertyNameCaseInsensitive = true,
	PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
	WriteIndented = true
};

var json = JsonSerializer.Serialize(model, options);
var model = await JsonSerializer.DeserializeAsync<Model>(stream, options);
```

**Conventions:**
- Use `System.Text.Json` (not Newtonsoft.Json)
- camelCase for JSON properties
- Async deserialization from streams
- Configure options once, reuse

---

## LINQ Style

### Query Syntax vs Method Syntax
```csharp
// Preferred: Method syntax
var activeEvents = events
	.Where(e => e.Status == EventStatus.Active)
	.OrderBy(e => e.CreatedAt)
	.Select(e => new EventDto
	{
		Id = e.EventId,
		CreatedAt = e.CreatedAt
	});
```

**Conventions:**
- Prefer method syntax over query syntax
- Chain on new lines for readability
- Use meaningful variable names
- Avoid complex nested queries (refactor to variables)

---

## Summary of Key Principles

1. **Clarity over Cleverness** - Readable code is maintainable code
2. **Consistency** - Follow established patterns
3. **Modern C#** - Use latest language features appropriately
4. **Dependency Injection** - Constructor injection for all dependencies
5. **Async All the Way** - No blocking on async operations
6. **Structured Logging** - Include context, use placeholders
7. **XML Documentation** - All public APIs documented
8. **Testing** - Arrange-Act-Assert, meaningful test names
9. **Configuration** - Externalize settings, use Key Vault for secrets
10. **Observability** - Instrument with OpenTelemetry

---

## Calculation Orchestrator sensitivity workflow rules

The following rules are verified for `PlanningSpace.Integration.Delfi.CalculationOrchestrator` at commit `88b4dcb8e457a06103be9e447024f30e9918844a` (task `task-1860579`).

- Resolve and validate sensitivity-variable aliases before `ManageProjects` or any outbound Planning Space request. This keeps invalid aliases fail-fast and prevents partial project mutation. Evidence: approved review finding `REV-005`, user decision `92a31240e899497eae62a1a6b21318ad`, clean review at the cited commit, and `CalculationControllerTests.cs:503-520`.
- Do not perform the controller-level hierarchy-node lookup merely to construct sensitivity settings when no Economic Limit override is supplied. Only the override path needs that lookup. Evidence: approved review finding `REV-006`, user decision `8074e805b7b1410aa1c9b125ce1cee54`, clean review at the cited commit, and `CalculationControllerTests.cs:598-607`.
