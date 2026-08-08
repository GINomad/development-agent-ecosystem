# PS-APP-DELFI: Knowledge Base Index

## Project Overview
**Project Name:** ps-app-delfi  
**Full Name:** PlanningSpace Integration Delfi Agent  
**Repository:** https://dev.azure.com/palantir-consulting/PalantirPlugins/_git/ps-app-delfi  
**Location:** C:\Repos\ps-app-delfi\  
**Framework:** .NET 10.0  
**Type:** ASP.NET Core Web API + Background Services

---

## Purpose
Integration agent that connects **Delfi/FDPlan** (Schlumberger's field development planning platform) and **Planning Space** (economic calculation and analysis platform) for automated economic calculations.

**High-Level Flow:**
```
FDPlan Events → ps-app-delfi Agent → Planning Space Calculations → Results back to FDPlan
```

---

## Knowledge Base Documents

This knowledge base contains comprehensive documentation about the ps-app-delfi project and its relationship to ps-excel-agent.

### 1. Architecture Overview
**File:** `ps-app-delfi_ARCHITECTURE_OVERVIEW.md`

**Contents:**
- High-level system architecture
- Architectural patterns (event-driven microservice)
- Core components (Agent, Event Processing, Data Layer, Clients)
- Integration points with FDPlan and Planning Space
- Event processing pipeline overview (30 steps)
- Design patterns used
- Background services
- API controllers overview
- Observability and monitoring
- Security architecture
- Deployment models
- Performance optimizations
- Testing strategy
- Relationship to ps-excel-agent
- Key technologies

**Key Sections:**
- System overview diagram
- Component responsibilities
- Data flow visualization
- Integration architecture
- Technology stack summary

---

### 2. API Contracts and Interfaces
**File:** `ps-app-delfi_API_CONTRACTS_AND_INTERFACES.md`

**Contents:**
- All interface definitions (35+ interfaces)
- Service contracts:
  - `IFDPlanService`, `IPlanningSpaceService`
  - `IDataConverter`, conversion interfaces
  - Controller interfaces for FDPlan, Planning Space, Dataflow
- Data models and contracts
- Contract design principles
- API versioning strategy
- Integration contract flow
- Extensibility patterns

**Key Sections:**
- Core service interfaces
- FDPlan client controllers
- Planning Space client controllers
- Dataflow client controllers
- Data conversion interfaces
- Helper and utility interfaces
- Common data models
- Contract flow diagrams

---

### 3. Code Style and Conventions
**File:** `ps-app-delfi_CODE_STYLE_AND_CONVENTIONS.md`

**Contents:**
- C# coding standards
- Naming conventions (interfaces, classes, methods, variables)
- File and namespace organization
- Dependency injection patterns
- Async/await best practices
- Error handling conventions
- XML documentation standards
- Project structure guidelines
- Configuration style
- Entity Framework conventions
- Service registration patterns
- Controller style guide
- Logging best practices
- Testing conventions
- LINQ style preferences
- Anti-patterns to avoid
- Code comment guidelines
- Resource management patterns

**Key Sections:**
- General C# style
- Naming conventions for all types
- Async patterns
- XML documentation examples
- Configuration structure
- Testing standards
- Logging patterns

---

### 4. Data Flow and Event Processing Pipeline
**File:** `ps-app-delfi_DATA_FLOW_AND_EVENT_PROCESSING.md`

**Contents:**
- Complete data flow from FDPlan to Planning Space and back
- Detailed 30-step event processing workflow:
  - Phase 1: Event Discovery and Validation (Steps 1-3)
  - Phase 2: Input Data Retrieval (Steps 4-8)
  - Phase 3: Data Transformation (Steps 9-12)
  - Phase 4: Planning Space Setup (Steps 13-17)
  - Phase 5: Calculation Execution (Steps 18-22)
  - Phase 6: Results Retrieval (Steps 23-25)
  - Phase 7: Results Upload to FDPlan (Steps 26-28)
  - Phase 8: Event Completion (Steps 29-30)
- Data structure examples (JSON)
- Transformation logic
- Dataflow processing (alternative path)
- Error handling and retry mechanisms
- Database schema and persistence
- Performance optimizations (throttling, parallel processing)

**Key Sections:**
- High-level data flow diagram
- Step-by-step event processing
- Data format examples
- Conversion patterns
- Retry and backoff logic
- State management

---

### 5. Dependencies and Technology Stack
**File:** `ps-app-delfi_DEPENDENCIES_AND_TECH_STACK.md`

**Contents:**
- Complete solution structure (23 projects)
- NuGet package dependencies by project:
  - Azure SDK packages
  - OpenTelemetry packages
  - ASP.NET Core packages
  - Aucerna proprietary packages
  - Testing frameworks
- Internal project references
- Dependency graph
- Technology stack summary
- Runtime requirements
- Configuration dependencies
- Network dependencies
- Version compatibility (file formats, APIs)
- Build configuration
- Embedded resources
- Licensing information
- Deployment package requirements

**Key Sections:**
- Production projects list
- Test projects list
- NuGet packages by category
- Project reference graph
- External API dependencies
- Supported file format versions

---

### 6. Relationship to ps-excel-agent
**File:** `ps-app-delfi_RELATIONSHIP_TO_PS_EXCEL_AGENT.md`

**Contents:**
- Comparison of ps-app-delfi and ps-excel-agent
- Architectural relationship
- Common components and patterns:
  - Planning Space API integration
  - Authentication patterns
  - Data models
  - Configuration management
- Functional roles and differences
- Potential integration points
- Complementary workflows
- Technical commonalities
- Key differences table
- Shared infrastructure opportunities
- Data format compatibility
- User scenarios involving both systems
- Security and access control alignment
- Future integration opportunities
- Developer collaboration recommendations

**Key Sections:**
- Side-by-side project comparison
- Shared components
- Integration workflows
- Complementary use cases
- Code reuse opportunities
- Summary comparison table

---

## Quick Reference

### Project Statistics
- **Total Projects:** 23 (13 production, 10 test)
- **Lines of Code:** ~50,000+ (estimated)
- **NuGet Packages:** ~50 dependencies
- **API Controllers:** 35+ interfaces
- **Target Framework:** .NET 10.0
- **Primary Language:** C# 12
- **Database:** SQLite (dev) / SQL Server (prod)

### Core Technologies
- ASP.NET Core 10.0 (Web API)
- Entity Framework Core (ORM)
- OpenTelemetry (Observability)
- Azure SDK (Key Vault, Monitor)
- Aucerna Libraries (Calculations)
- MSTest + Moq (Testing)

### External Systems
1. **FDPlan (Delfi)** - Schlumberger platform
   - API: https://eu-api.delfi.slb.com/fdplan/
   - Authentication: OAuth2 client credentials

2. **Planning Space** - Economic calculation engine
   - API: Configurable (e.g., https://ps-uat01.qdev.net/)
   - Authentication: OAuth2 JWT bearer tokens

3. **Azure Services** - Cloud infrastructure
   - Key Vault for secrets
   - Azure Monitor for telemetry

### Key Components
1. **EventProcessor** - Orchestrates 30-step workflow
2. **CalculationManager** - Manages PS calculations
3. **DataConverter** - FDPlan ↔ Planning Space transformations
4. **Storage** - Database repository
5. **FDPlanClient** - FDPlan API client
6. **PlanningSpaceClient** - Planning Space API client

### Integration Patterns
- **Event-Driven:** Polls FDPlan for computation events
- **REST API:** HTTP/JSON communication
- **Retry Logic:** Exponential backoff for transient errors
- **Throttling:** Rate limiting to prevent API overload
- **State Management:** Local database tracking

### Data Flow Stages
1. Event Discovery → 2. Input Retrieval → 3. Data Transformation → 
4. PS Setup → 5. Calculation → 6. Results Retrieval → 
7. Results Upload → 8. Completion & Cleanup

---

## How to Use This Knowledge Base

### For Developers
1. **New Team Member:**
   - Start with: Architecture Overview
   - Then read: Code Style and Conventions
   - Reference: API Contracts for interface details

2. **Debugging Data Issues:**
   - Consult: Data Flow and Event Processing Pipeline
   - Check: API Contracts for data model definitions

3. **Adding New Features:**
   - Review: Architecture Overview for design patterns
   - Follow: Code Style and Conventions
   - Update: Relevant knowledge documents

4. **Integration Work:**
   - Read: Relationship to ps-excel-agent
   - Review: API Contracts for shared interfaces

### For System Administrators
1. **Deployment:**
   - Dependencies and Technology Stack (runtime requirements)
   - Architecture Overview (deployment models)

2. **Configuration:**
   - Code Style and Conventions (configuration structure)
   - Dependencies (network and external system requirements)

3. **Monitoring:**
   - Architecture Overview (observability section)
   - Data Flow (error handling and retry logic)

### For Architects
1. **System Design:**
   - Architecture Overview (patterns and components)
   - API Contracts (interface design)

2. **Integration Planning:**
   - Relationship to ps-excel-agent (integration opportunities)
   - Data Flow (pipeline architecture)

3. **Technology Decisions:**
   - Dependencies and Technology Stack (current choices)
   - Architecture Overview (design rationale)

---

## Document Maintenance

### Updating Guidelines
1. **When to Update:**
   - Major architectural changes
   - New API interfaces added
   - Coding standards changed
   - New integration points
   - Technology stack updates

2. **How to Update:**
   - Update relevant document(s)
   - Add version/date at top if needed
   - Update this index if new documents added
   - Cross-reference related documents

3. **Version Control:**
   - All documents stored in: `C:\Repos\AI Knowledge\ps_excel_agent\`
   - Files prefixed with `ps-app-delfi_` for clarity
   - Git track changes for history

---

## Document Cross-References

### Architecture → Other Documents
- **API Contracts:** Interface details for components
- **Code Style:** Implementation standards for architecture
- **Data Flow:** Detailed workflow of architecture
- **Dependencies:** Technologies supporting architecture

### API Contracts → Other Documents
- **Architecture:** Context for interface design
- **Code Style:** Naming and documentation standards
- **Data Flow:** How interfaces are used in pipeline

### Code Style → Other Documents
- **API Contracts:** Examples of interface documentation
- **Architecture:** Dependency injection patterns
- **Data Flow:** Logging and error handling examples

### Data Flow → Other Documents
- **Architecture:** High-level pipeline overview
- **API Contracts:** Controller methods used in each step
- **Dependencies:** Libraries for data transformation

### Dependencies → Other Documents
- **Architecture:** How technologies fit together
- **Data Flow:** Libraries used in transformations
- **Relationship:** Shared dependencies with ps-excel-agent

### Relationship → Other Documents
- **Architecture:** Comparison of architectures
- **API Contracts:** Shared interfaces
- **Dependencies:** Common technology stack

---

## Related Projects

### ps-excel-agent
**Location:** C:\Repos\ps-excel-agent\  
**Knowledge Base:** Same folder (C:\Repos\AI Knowledge\ps_excel_agent\)  
**Relationship:** Complementary Planning Space integration (Excel-based)

### Connection Points
- Both use Planning Space APIs
- Both handle economic data
- Both use OAuth2 authentication
- Potential for shared libraries and models

---

## Additional Resources

### External Documentation
- **FDPlan API:** Delfi Portal documentation
- **Planning Space API:** Planning Space developer docs
- **Azure Key Vault:** Microsoft Azure documentation
- **OpenTelemetry:** https://opentelemetry.io/

### Internal Resources
- **Solution README:** C:\Repos\ps-app-delfi\README.md
- **API Swagger:** https://localhost:5000/swagger (when running)
- **Configuration Files:** appsettings.json, appsettings.Defaults.json

---

## Contact and Support

### Development Team
- Repository: Azure DevOps (palantir-consulting/PalantirPlugins)
- Branch: main
- Remote: https://dev.azure.com/palantir-consulting/PalantirPlugins/_git/ps-app-delfi

### Knowledge Base Maintenance
- Location: C:\Repos\AI Knowledge\ps_excel_agent\
- Purpose: Centralized documentation for Planning Space integrations
- Scope: ps-app-delfi and ps-excel-agent projects

---

## Glossary

**FDPlan** - Schlumberger's Field Development Planning platform (part of Delfi)  
**Delfi** - Schlumberger's digital platform for energy  
**Planning Space** - Economic calculation and analysis platform (Aucerna/Quorum)  
**Agent** - The ps-app-delfi integration service  
**Event** - FDPlan computation request  
**Computation** - Calculation task in FDPlan  
**Hierarchy** - Project structure in Planning Space  
**Container** - Data package in FDPlan  
**Economic Framework** - Economic assumptions and settings  
**Variable** - Data item in Planning Space (time series or scalar)  
**Register** - Opportunity register data structure  
**NPV** - Net Present Value  
**IRR** - Internal Rate of Return  
**CAPEX** - Capital Expenditure  
**OPEX** - Operational Expenditure  

**Technical Terms:**  
**EF Core** - Entity Framework Core (ORM)  
**DI** - Dependency Injection  
**OTLP** - OpenTelemetry Protocol  
**JWT** - JSON Web Token  
**OAuth2** - Open Authorization 2.0 protocol  
**REST** - Representational State Transfer (API style)  

---

## Document Versions

| Document | Created | Last Updated | Version |
|----------|---------|--------------|---------|
| Architecture Overview | 2024-01-15 | 2024-01-15 | 1.0 |
| API Contracts | 2024-01-15 | 2024-01-15 | 1.0 |
| Code Style | 2024-01-15 | 2024-01-15 | 1.0 |
| Data Flow | 2024-01-15 | 2024-01-15 | 1.0 |
| Dependencies | 2024-01-15 | 2024-01-15 | 1.0 |
| Relationship | 2024-01-15 | 2024-01-15 | 1.0 |
| Index (this file) | 2024-01-15 | 2024-01-15 | 1.0 |

---

## Summary

This knowledge base provides comprehensive documentation for the **ps-app-delfi** project, covering:
- ✅ Architecture and design patterns
- ✅ Complete API interface catalog
- ✅ Coding standards and conventions
- ✅ End-to-end data flow and processing
- ✅ Technology stack and dependencies
- ✅ Relationship to ps-excel-agent project

**Total Pages:** ~100+ pages of documentation  
**Coverage:** Architecture, Code, APIs, Data Flow, Tech Stack, Integration  
**Audience:** Developers, Administrators, Architects  
**Maintenance:** Living documents, updated as project evolves

Use this knowledge base as your primary reference for understanding, developing, and maintaining the ps-app-delfi integration agent.
