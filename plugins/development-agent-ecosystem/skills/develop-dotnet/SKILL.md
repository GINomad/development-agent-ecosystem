---
name: develop-dotnet
description: Implement and review modern C# and .NET code using repository-compatible architecture, dependency injection, async and cancellation, exception handling, nullable safety, analyzers, and focused automated tests. Use for .cs, .csproj, ASP.NET Core, worker, library, and test-project changes.
---

# Develop .NET code

1. Inspect target frameworks, nullable settings, analyzers, package versions, architecture, and test conventions before designing.
2. Keep business rules independent from infrastructure where the existing architecture supports that boundary. Dependencies point toward stable policy; composition belongs at the application edge.
3. Prefer constructor injection and small cohesive services. Do not introduce an interface without a real boundary, alternate implementation, or test seam.
4. Preserve nullable annotations. Validate public inputs and avoid null-forgiving operators unless an invariant is evidenced.
5. Use `async` end to end for I/O. Accept and propagate `CancellationToken` through cancellable work; do not swallow `OperationCanceledException` as an ordinary failure.
6. Use standard exception types, preserve stack traces with `throw`, and catch only when adding recovery, cleanup, or material context.
7. Dispose owned resources correctly. Let the DI container dispose services it creates; do not resolve disposable transients from the root container without a bounded scope.
8. Prefer readable language and framework features supported by the repository target. Do not upgrade target frameworks or packages without task evidence and approval.
9. Add the narrowest useful unit tests for pure policy and integration tests for infrastructure boundaries. Run formatting, analyzers, build, and affected tests using repository commands.
10. Reviewer: check behavior, cancellation, concurrency, lifetime, disposal, exception, compatibility, and test evidence before stylistic preferences.

## Official references

- [.NET common web application architectures](https://learn.microsoft.com/en-us/dotnet/architecture/modern-web-apps-azure/common-web-application-architectures)
- [.NET dependency injection guidelines](https://learn.microsoft.com/en-us/dotnet/core/extensions/dependency-injection/guidelines)
- [.NET exception best practices](https://learn.microsoft.com/en-us/dotnet/standard/exceptions/best-practices-for-exceptions)
- [.NET task cancellation](https://learn.microsoft.com/en-us/dotnet/standard/parallel-programming/task-cancellation)
