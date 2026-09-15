---
name: company-dotnet-review
description: Apply company-specific .NET correctness and maintainability checks during pull request review.
---

# Company .NET Review

- Check cancellation-token propagation across asynchronous call chains.
- Flag new blocking calls such as `.Result`, `.Wait()`, and synchronous I/O in request paths.
- Verify scoped services are not captured by singleton services.
- Require evidence before reporting an issue; do not report style-only preferences as defects.
- Include the concrete runtime impact and the smallest reasonable correction direction.
