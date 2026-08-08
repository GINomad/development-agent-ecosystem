# ProjectScenarioName and Scenario Configuration in ps-app-delfi

## Investigation Date
January 15, 2024

## Context
Investigation into the `ProjectScenarioName` property in `CalculationInputModel.cs` to understand what values are expected and how scenarios are used in the Planning Space integration.

---

## Overview

`ProjectScenarioName` is a string property that represents the name of a **Planning Space economic scenario** used during calculation execution. It is a critical parameter that determines which set of economic assumptions and parameters are applied to projects during economic calculations.

---

## Property Definition

### Location
**File:** `PlanningSpace.Integration.Delfi.CalculationOrchestrator\Models\CalculationInputModel.cs`

```csharp
namespace PlanningSpace.Integration.CalculationOrchestrator.Models
{
	public class CalculationInputModel
	{
		public int HierarchyId { get; set; }
		public string[] ResultVariableIds { get; set; }
		public string[] PartnerNames { get; set; }
		public int? CurrencyDeckId { get; set; }
		public int? PriceDeckId { get; set; }
		public string PriceScenarioName { get; set; }
		public string ProjectScenarioName { get; set; }  // ← This property
		public bool UseDistributedProcessing { get; set; }
	}
}
```

---

## Expected Values

### Common Scenario Names Found in Codebase

| Scenario Name | Context | Source File |
|--------------|---------|-------------|
| `"Base"` | Default/most common scenario | Multiple test files |
| `"Low"` | Low price scenario | README.md example |
| `"My Project Scenario"` | Custom scenario example | CalculationControllerTests.cs |
| `"Project"` | Simple generic name | CalculationControllerTests.cs |

### Nature of the Value
- **Type:** String (free-text, not an enum)
- **Validation:** No hard-coded validation in the agent code
- **Source:** Configured in economic framework mapping files
- **Must Match:** The scenario name should exist in Planning Space project configuration

### Typical Naming Conventions
Based on industry standards and Planning Space conventions:
- **Base Case:** "Base", "Base Case", "Reference"
- **Price Scenarios:** "Low", "Mid", "High"
- **Probability Scenarios:** "P10", "P50", "P90" (pessimistic, expected, optimistic)
- **Custom Scenarios:** "Optimistic", "Pessimistic", "Conservative", "Aggressive"

---

## Data Flow

### 1. Source: Economic Framework Mapping File

The scenario name originates from the economic framework mapping configuration:

**Location:** Economics mapping `.jsonc` file (e.g., `econ-framework.json`)

**Structure:**
```json
{
  "InputVariables": {
	"ApplyWorkingInterestToAllScenarios": true,
	"InheritWorkingInterest": true,
	"IsDefaultScenarioFailure": false,
	"ProjectScenarioName": "Base",  // ← Defined here
	"ScalarConversionOption": "",
	"Variables": [
	  {
		"PSVariableName": "Production_Liquids_Condensate_Rate",
		"FDPlanVariableName": "PRODUCTION_RATE_LIQUID",
		"ScenarioName": "Base",  // ← Also used per variable
		// ... other properties
	  }
	]
  }
}
```

### 2. Model: EconomicsMappingModel

**File:** `PlanningSpace.Integration.Delfi.Conversions\Models\EconomicsMappingModel.cs`

```csharp
public class InputVariablesSpecification
{
	public bool ApplyWorkingInterestToAllScenarios { get; set; }
	public bool InheritWorkingInterest { get; set; }
	public bool IsDefaultScenarioFailure { get; set; }
	public string ProjectScenarioName { get; set; }  // ← Property in model
	public string ScalarConversionOption { get; set; }
	public string PeriodicDataTransformationStrategy { get; set; }
	public IEnumerable<InputVariableMappingModel> Variables { get; set; }
	public IEnumerable<InputUnitConversion> UnitConversion { get; set; }
}
```

### 3. Transformation: CalculationInputConverter

**File:** `PlanningSpace.Integration.Delfi.Conversions\FDPlanToEconomicsConverters\CalculationInputConverter.cs`

The scenario name is used to create both **ProjectSettings** and **ScenarioModel**:

```csharp
// Project Settings (lines 36-48)
var psSettings = new ProjectSettingsModel()
{
	ApplyWorkingInterestToAllScenarios = spec.ApplyWorkingInterestToAllScenarios,
	ChosenScalarConversionDate = startDate,
	InheritWorkingInterest = spec.InheritWorkingInterest,
	Duration = (short?)yearDates.Count,
	InflationDate = inflationDate,
	IsDefaultScenarioFailure = spec.IsDefaultScenarioFailure,
	ProjectScenarioName = spec.ProjectScenarioName,  // ← Used here
	ScalarConversionOption = EnumFromString<ScalarConversionDateOption>(spec.ScalarConversionOption),
	PeriodicDataTransformationStrategy = EnumFromString<StartYearChangeOption>(strategy),
	StartYear = (short?)startDate?.Year
};

// Scenario Model (lines 50-56)
var psScenario = new ScenarioModel()
{
	Name = spec.ProjectScenarioName,  // ← Used as scenario name
	IsEconomicLimitCalculated = true,
	MinimumMonthsToEvaluate = 12,
	Weighting = 100,
};

List<ScenarioModel> psScenarios = new()
{
	psScenario  // Added to scenarios collection
};
```

### 4. Usage in DataTransformer

**File:** `PlanningSpace.Integration.Delfi.Agent\DataTransformer.cs` (line 98)

```csharp
ProjectScenarioName = variableMappings.InputVariables.ProjectScenarioName
```

The value flows from the mapping model to the calculation input model.

### 5. Calculation Execution: CalculationController

**File:** `PlanningSpace.Integration.Delfi.CalculationOrchestrator\CalculationController.cs`

#### Traditional Calculation API (lines 135-145)
```csharp
var payload = new CalculationInputModel
{
	HierarchyId = hierarchyId,
	ResultVariableIds = resultVariableIds.Select(id => id.ToString()).ToArray(),
	PartnerNames = model.InputData.PartnerNames,
	CurrencyDeckId = currencyDeckId == 0 ? null : currencyDeckId,
	PriceDeckId = priceDeckId == 0 ? null : priceDeckId,
	PriceScenarioName = model.InputData.PriceScenarioName,
	ProjectScenarioName = model.InputData.ProjectScenarioName,  // ← Sent to Planning Space
	UseDistributedProcessing = distributed,
};
```

#### Result Sets API (lines 167-194)
```csharp
var resultSetsPayload = new ResultSetsPayloadModel
{
	Name = "PS-FDPlan Calc API Result Set " + nameSuffix,
	HierarchyId = hierarchyId,
	IsSelectAllProjects = true,
	Path = @"API\FDPlan Service",
	Runs = new List<ResultSetsRunModel>
	{
		new ResultSetsRunModel
		{
			Name = "API Run " + nameSuffix,
			CurrencyDeckId = currencyDeckId == 0 ? null : currencyDeckId,
			PriceDeckId = priceDeckId == 0 ? null : priceDeckId,
			PriceScenarioName = model.InputData.PriceScenarioName,
			ProjectScenarioName = model.InputData.ProjectScenarioName,  // ← Also used here
			EconomicLimitSettings = new List<ResultSetsEconomicLimitModel>
			{
				// ... economic limit configuration
			}
		}
	}
};
```

#### Advanced Calculation API (lines 225-235)
```csharp
var payload = new CreateCalculationSettings
{
	BaseUri = new Uri(_planningSpaceService.GetTenantUrl()),
	ResultVariableIds = resultVariableIds,
	PartnerNames = model.InputData.PartnerNames,
	CurrencyDeckId = currencyDeckId == 0 ? hierarchy.CurrencyDeckId : currencyDeckId,
	PriceDeckId = priceDeckId == 0 ? hierarchy.PriceDeckId : priceDeckId,
	PriceScenarioName = model.InputData.PriceScenarioName,
	ProjectScenarioName = model.InputData.ProjectScenarioName,  // ← And here
	UseDistributedProcessing = distributed,
};
```

---

## Complete Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. Economic Framework Mapping File (econ-framework.json)       │
│    InputVariables.ProjectScenarioName: "Base"                  │
└────────────────────────┬────────────────────────────────────────┘
						 │
						 ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2. EconomicsMappingModel                                        │
│    InputVariablesSpecification.ProjectScenarioName             │
└────────────────────────┬────────────────────────────────────────┘
						 │
						 ↓
┌─────────────────────────────────────────────────────────────────┐
│ 3. CalculationInputConverter                                    │
│    Creates:                                                     │
│    - ProjectSettingsModel.ProjectScenarioName                  │
│    - ScenarioModel.Name                                        │
└────────────────────────┬────────────────────────────────────────┘
						 │
						 ↓
┌─────────────────────────────────────────────────────────────────┐
│ 4. DataTransformer                                              │
│    Maps to CalculationInputModel.ProjectScenarioName           │
└────────────────────────┬────────────────────────────────────────┘
						 │
						 ↓
┌─────────────────────────────────────────────────────────────────┐
│ 5. CalculationController                                        │
│    Sends to Planning Space API:                                │
│    - Traditional Calculation API                               │
│    - Result Sets API                                           │
│    - Advanced Calculation API                                  │
└────────────────────────┬────────────────────────────────────────┘
						 │
						 ↓
┌─────────────────────────────────────────────────────────────────┐
│ 6. Planning Space Economics Engine                             │
│    Uses scenario to apply economic parameters                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Relationship to Other Scenario Properties

### ProjectScenarioName vs PriceScenarioName

Both properties exist in `CalculationInputModel`, but serve different purposes:

| Property | Purpose | Example Values |
|----------|---------|----------------|
| `ProjectScenarioName` | Economic scenario for project-level parameters (costs, timing, etc.) | "Base", "Optimistic" |
| `PriceScenarioName` | Price scenario from the price deck (commodity prices) | "Low", "Mid", "High" |

**Example Combination:**
- `ProjectScenarioName = "Base"` (base case project parameters)
- `PriceScenarioName = "Low"` (low oil/gas prices)
- **Result:** Base case project with low commodity prices scenario

### ScenarioName per Variable

In the `InputVariableMappingModel`, each variable can also specify a `ScenarioName`:

```csharp
public class InputVariableMappingModel
{
	public string PSVariableName { get; set; }
	public string FDPlanVariableName { get; set; }
	public string FDPlanVariableSecondaryName { get; set; }
	public string ScenarioName { get; set; }  // ← Per-variable scenario
	// ... other properties
}
```

**Usage:** This allows different variables to come from different scenarios, though typically all variables use the same scenario as `ProjectScenarioName`.

---

## Test Examples

### Example 1: Basic Test Setup
**Source:** `CalculationControllerTests.cs` (line 56)

```csharp
var payload = new CalculationModel
{
	InputData = new CalculationInputDataModel
	{
		ProjectScenarioName = "My Project Scenario",
		PriceScenarioName = "Low",
		// ... other properties
	}
};
```

### Example 2: Conversion Test
**Source:** `CalculationInputConverterTests.cs` (line 22)

```csharp
private static InputVariablesSpecification GetDefinition()
{
	return new InputVariablesSpecification
	{
		ApplyWorkingInterestToAllScenarios = true,
		InheritWorkingInterest = true,
		IsDefaultScenarioFailure = false,
		ProjectScenarioName = "Base",  // ← Most common test value
		ScalarConversionOption = "",
		Variables = new List<InputVariableMappingModel>
		{
			new()
			{
				PSVariableName = "Production_Liquids_Condensate_Rate",
				FDPlanVariableName = "PRODUCTION_RATE_LIQUID",
				ScenarioName = "Base",  // ← Matches ProjectScenarioName
				ScalingFactor = 1000,
				Currency = "USD",
				// ... other properties
			}
		}
	};
}
```

### Example 3: README Configuration
**Source:** `README.md` (line 549)

```json
{
  "name": "Sample Model",
  "version": 1,
  "templateHierarchyName": "FDPlan Calculations",
  "hierarchyFolder": "Corporate Rollup",
  "currencyDeckName": "Reference Currency 2017",
  "priceDeckName": "Reference Price 2017",
  "priceScenarioName": "Low",
  "wiPartner": "Company",
  "filterProjects": "true",
  "saveResult": "false"
}
```
*Note: While this example doesn't show `projectScenarioName`, it demonstrates the configuration pattern.*

---

## Scenario Model Properties

Based on the code in `CalculationInputConverter.cs`, when a `ScenarioModel` is created:

```csharp
var psScenario = new ScenarioModel()
{
	Name = spec.ProjectScenarioName,          // The scenario name
	IsEconomicLimitCalculated = true,         // Enable economic limit calculations
	MinimumMonthsToEvaluate = 12,            // Minimum evaluation period
	Weighting = 100,                          // Scenario weighting (100%)
};
```

**Properties:**
- **Name:** The scenario name from `ProjectScenarioName`
- **IsEconomicLimitCalculated:** Always set to `true` (calculates when project becomes uneconomic)
- **MinimumMonthsToEvaluate:** Set to 12 months (minimum period to evaluate economics)
- **Weighting:** Set to 100 (100% weighting for this scenario)

*Note: `ScenarioModel` is from the Aucerna.Calculation.Advanced.Models namespace, so additional properties may exist in that external library.*

---

## Configuration Requirements

### JSON Schema Validation

The `ProjectScenarioName` is **required** in all economics file format versions:

**Source:** Multiple economics format files (`economics-1.4.jsonc` through `economics-1.8.jsonc`)

```jsonc
{
  "InputVariables": {
	"type": "object",
	"properties": {
	  "ProjectScenarioName": { "type": "string" },
	  // ... other properties
	},
	"required": [
	  "ApplyWorkingInterestToAllScenarios",
	  "InheritWorkingInterest",
	  "IsDefaultScenarioFailure",
	  "ProjectScenarioName",  // ← Required field
	  "ScalarConversionOption",
	  "Variables"
	]
  }
}
```

### Documentation Template

**Source:** `documentation\mapping files\Economics mapping file template.jsonc` (line 87)

```jsonc
{
  "InputVariables": {
	// Required: ApplyWorkingInterestToAllScenarios, InheritWorkingInterest, 
	// IsDefaultScenarioFailure, ProjectScenarioName, ScalarConversionOption, Variables

	"ApplyWorkingInterestToAllScenarios": false,
	"InheritWorkingInterest": false,
	"IsDefaultScenarioFailure": false,
	"ProjectScenarioName": "string",  // ← Required string value
	"ScalarConversionOption": "string",
	"PeriodicDataTransformationStrategy": "string", // either "Shift" or "Truncate"
	// ... rest of configuration
  }
}
```

---

## Planning Space Economics Context

### What is a Project Scenario?

In Planning Space Economics, a **project scenario** represents a set of economic assumptions and parameters applied to projects during calculations. Multiple scenarios allow users to evaluate different cases:

**Common Use Cases:**
1. **Sensitivity Analysis:** Run same project with different assumptions (e.g., "Base", "Optimistic", "Pessimistic")
2. **Probability Analysis:** P10/P50/P90 scenarios for probabilistic evaluations
3. **Strategy Comparison:** Different development strategies or timing scenarios

### Scenario Application in Planning Space

When a calculation runs:
1. **Project Settings** are configured with `ProjectScenarioName`
2. **Scenario Model** is created with that name
3. **Planning Space Economics Engine** applies the scenario's parameters:
   - Cost assumptions (CAPEX, OPEX)
   - Timing assumptions
   - Working interest settings
   - Fiscal regime parameters
4. **Results** are tagged with the scenario name for comparison

---

## Best Practices

### Naming Conventions

1. **Be Descriptive:**
   - ✅ "Base_Case", "High_Production", "Delayed_Development"
   - ❌ "Scenario1", "Test", "Temp"

2. **Use Consistent Patterns:**
   - For price sensitivities: "Low_Price", "Mid_Price", "High_Price"
   - For probability: "P10", "P50", "P90"
   - For strategies: "Fast_Track", "Standard_Development", "Phased_Development"

3. **Avoid Special Characters:**
   - Use underscores or hyphens, not spaces (if Planning Space has restrictions)
   - Keep names alphanumeric when possible

4. **Keep It Short:**
   - Scenario names may appear in UI dropdowns and reports
   - Recommended: 20 characters or less

### Configuration Management

1. **Document Your Scenarios:**
   - Maintain a mapping document explaining what each scenario represents
   - Include assumptions that differ from base case

2. **Version Control:**
   - Store economic framework mapping files in version control
   - Track changes to scenario definitions

3. **Validation:**
   - Ensure scenario names in configuration match Planning Space setup
   - Verify scenario names are consistent across all mapping variables

---

## Common Issues and Troubleshooting

### Issue 1: Scenario Not Found in Planning Space

**Symptom:** Calculation fails with scenario-related error

**Causes:**
- Scenario name mismatch between configuration and Planning Space
- Typo in scenario name
- Scenario doesn't exist in Planning Space project

**Solutions:**
1. Verify scenario exists in Planning Space using the UI
2. Check for exact match (case-sensitive)
3. Review economic framework mapping file for typos

### Issue 2: Inconsistent Scenario Names

**Symptom:** Some variables use different scenario names

**Causes:**
- Per-variable `ScenarioName` differs from `ProjectScenarioName`
- Mixed scenario usage in mapping configuration

**Solutions:**
1. Standardize on single scenario name
2. Update all variable mappings to use same scenario
3. Only use per-variable scenarios if intentionally mixing scenarios

### Issue 3: Empty or Null Scenario Name

**Symptom:** Validation error or calculation failure

**Causes:**
- `ProjectScenarioName` not set in mapping file
- JSON parsing issue

**Solutions:**
1. Ensure `ProjectScenarioName` is populated in mapping configuration
2. Validate JSON schema compliance
3. Check for required field presence

---

## Related Configuration Properties

### ProjectSettingsModel

**Properties influenced by scenario configuration:**
```csharp
public class ProjectSettingsModel
{
	public bool ApplyWorkingInterestToAllScenarios { get; set; }
	public DateTime? ChosenScalarConversionDate { get; set; }
	public bool InheritWorkingInterest { get; set; }
	public short? Duration { get; set; }
	public DateTime? InflationDate { get; set; }
	public bool IsDefaultScenarioFailure { get; set; }
	public string ProjectScenarioName { get; set; }  // ← The scenario name
	public ScalarConversionDateOption? ScalarConversionOption { get; set; }
	public StartYearChangeOption? PeriodicDataTransformationStrategy { get; set; }
	public short? StartYear { get; set; }
}
```

### Related Boolean Flags

**ApplyWorkingInterestToAllScenarios:**
- When `true`, working interest calculations apply to all scenarios
- Affects how ownership percentages are calculated across scenarios

**InheritWorkingInterest:**
- When `true`, inherits working interest from parent hierarchy
- Simplifies configuration when using standard ownership structure

**IsDefaultScenarioFailure:**
- Determines behavior when scenario parameters are missing
- `true`: Fail calculation if scenario incomplete
- `false`: Use default values

---

## Summary

### Key Takeaways

1. **ProjectScenarioName is a free-text string** representing an economic scenario name
2. **Configured in economic framework mapping files** under `InputVariables.ProjectScenarioName`
3. **Used throughout the calculation pipeline** from model creation to API submission
4. **Most common value is "Base"** for base case scenarios
5. **Must match Planning Space configuration** for successful calculations
6. **Distinct from PriceScenarioName** which controls commodity price scenarios

### Typical Values Summary

| Value | Use Case | Frequency |
|-------|----------|-----------|
| "Base" | Default/base case | Very Common |
| "Low" | Low price or conservative | Common |
| "High" | High price or optimistic | Common |
| "P10" / "P50" / "P90" | Probabilistic scenarios | Common |
| Custom names | Project-specific scenarios | Variable |

### Integration Flow

```
Economic Framework Config → EconomicsMappingModel → CalculationInputConverter 
→ ProjectSettingsModel + ScenarioModel → CalculationInputModel 
→ Planning Space API → Economic Calculation
```

---

## References

### Source Files Analyzed

1. `PlanningSpace.Integration.Delfi.CalculationOrchestrator\Models\CalculationInputModel.cs`
2. `PlanningSpace.Integration.Delfi.Conversions\Models\EconomicsMappingModel.cs`
3. `PlanningSpace.Integration.Delfi.Conversions\FDPlanToEconomicsConverters\CalculationInputConverter.cs`
4. `PlanningSpace.Integration.Delfi.Agent\DataTransformer.cs`
5. `PlanningSpace.Integration.Delfi.CalculationOrchestrator\CalculationController.cs`
6. `PlanningSpace.Integration.Delfi.ConversionsTests\CalculationInputConverterTests.cs`
7. `PlanningSpace.Integration.Delfi.CalculationOrchestratorTests\CalculationControllerTests.cs`
8. `documentation\mapping files\Economics mapping file template.jsonc`
9. `PlanningSpace.Integration.Delfi.Conversions\FileFormats\economics-1.4.jsonc` through `economics-1.8.jsonc`
10. `README.md`

### External Dependencies

- **Aucerna.Calculation.Advanced.Models**: Contains `ScenarioModel` and related types
- **Planning Space Economics API**: Consumes the scenario name for calculations

---

## Investigation Notes

### Search Patterns Used
- `ProjectScenarioName` (property usage)
- `ScenarioModel` (model definition and usage)
- `class ScenarioModel` (class definition search)
- `scenario` (general concept search)

### Files with Most Relevant Information
1. **CalculationInputConverter.cs**: Shows how scenario models are created
2. **CalculationController.cs**: Shows how scenarios are sent to Planning Space
3. **Test files**: Provide concrete examples of scenario names in use
4. **Economics mapping template**: Documents configuration structure

### Uncertainties and Questions for Future Investigation
1. **ScenarioModel properties**: Full definition is in Aucerna external library
2. **Planning Space scenario system**: How scenarios are configured in Planning Space UI
3. **Scenario validation**: Whether Planning Space validates scenario names exist
4. **Multi-scenario calculations**: Whether multiple scenarios can run simultaneously

---

## Document Metadata

**Created:** January 15, 2024  
**Project:** ps-app-delfi (PlanningSpace Integration Delfi Agent)  
**Context:** Investigation of ProjectScenarioName property  
**Related Documentation:** 
- ps-app-delfi_ARCHITECTURE_OVERVIEW.md
- ps-app-delfi_API_CONTRACTS_AND_INTERFACES.md
- ps-app-delfi_DATA_FLOW_AND_EVENT_PROCESSING.md

**Purpose:** Knowledge capture for future reference and onboarding
