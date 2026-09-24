# [Report Designer] Integrate the Report Designer component into Planning Space Web

**Parent Feature:** 1865781 - Webify an Excel based editor  
**User Story estimate:** 8 Story Points  
**Development child Task estimate:** 24 hours  

The Story Point estimate represents the complete delivery effort. The child Task estimate covers development only: implementation, developer-owned automated tests, code-review fixes, and technical handoff. QA execution and acceptance testing must be tracked in a separate child Task.

## User Story

**As a** Report Author,  
**I want** the Report Designer component to open inside Planning Space Web for a selected report template,  
**so that** I can edit the report template without launching the desktop application.

## Description

Integrate the Report Designer component into the existing Planning Space Angular application. Planning Space Web must provide the application route and host container, while the server loads the selected report template into an isolated editor session.

The integration must establish a secure and explicit contract between the Angular application and the Report Designer host. The contract must carry the authenticated user, tenant, selected template, editor session, readiness, dirty state, errors, and close/dispose events without trusting client-supplied authorization decisions.

This story delivers the editor shell and component lifecycle. It does not implement report-variable linking, link attributes, Range links, Discount Rate links, migration, or final database persistence of edited templates.

## Acceptance Criteria

1. **Open the designer from Planning Space Web**
   - Given an authenticated user has access to a report template,
   - when Planning Space Web navigates to the Report Designer route with that template selected,
   - then the Report Designer is displayed inside the Planning Space Web layout without opening a separate desktop application or browser window.

2. **Load the selected template**
   - Given a valid template identifier and authorized user,
   - when the Report Designer initializes,
   - then the server loads the corresponding workbook into the editor session and the editor displays the expected worksheets, values, formulas, styles, merged cells, and named ranges.
   - The developer verification must use a representative existing desktop-authored template rather than only a newly generated empty workbook.

3. **Enforce authorization on the server**
   - Given a user does not have permission to open the selected template or the template belongs to another tenant,
   - when the editor is requested,
   - then the server rejects the request and no workbook content is returned to the client.
   - Changing a template, tenant, or session identifier in the browser must not bypass this check.

4. **Use an isolated editor session**
   - Given two users or two browser tabs open Report Designer sessions,
   - when they load the same or different templates,
   - then each session has its own document state and cannot read or modify another session's workbook through its session identifier.

5. **Establish a validated host communication contract**
   - Given the Angular host and Report Designer exchange lifecycle messages,
   - when a message is received,
   - then its origin, source, session identifier, message type, and payload schema are validated before it is processed.
   - The contract supports at least: initialized, ready, dirty-state changed, load failed, session expired, and close/dispose.

6. **Display loading and failure states**
   - Given the Report Designer is loading, fails to initialize, cannot load the template, or the session expires,
   - when the corresponding state occurs,
   - then Planning Space Web displays a clear loading or error state and provides the appropriate retry or return action without leaving an unusable editor surface.

7. **Clean up the editor lifecycle**
   - Given the user leaves the Report Designer route or closes the editor,
   - when the component is disposed,
   - then client subscriptions and listeners are removed and the server session is released or marked for bounded cleanup.
   - Repeated open/close cycles must not reuse another user's document or accumulate duplicate message handlers.

8. **Expose dirty state without claiming persistence**
   - Given the user changes the workbook in the Report Designer,
   - when the editor reports a document change,
   - then Planning Space Web records and displays the dirty state through the integration contract.
   - This criterion does not require saving the workbook to the Planning Space database; persistence is owned by a separate story.

9. **Meet the agreed web compatibility baseline**
   - Given the supported browser and viewport matrix,
   - when the Report Designer is opened,
   - then its ribbon, worksheet tabs, formula bar, and scrollable grid remain usable within the Planning Space layout.

## Implementation Plan

1. Define a versioned integration contract for route parameters, editor-session creation, initialization, readiness, dirty state, errors, expiry, and disposal.
2. Add the Angular Report Designer route and host component using existing Planning Space routing, authorization, loading-state, error-state, and cleanup patterns.
3. Add or adapt the server-side editor host so it resolves the authenticated tenant and user, checks template access, loads the workbook through existing report services, and creates an isolated editor session.
4. Implement the host bridge with strict origin, source, session, message-type, and payload validation. Apply the required framing, cookie, and anti-forgery controls.
5. Wire editor lifecycle and dirty-state events into the Angular host. Release client and server resources when the editor closes, expires, or fails.
6. Add developer-owned tests for route initialization, authorization failure, tenant isolation, message rejection, loading and error states, repeated open/close, and representative workbook rendering.
7. Run a browser smoke test with an existing desktop-authored template and record unsupported workbook behavior as follow-up scope.
8. Prepare the build, fixture, and supported-scenario list for the separate QA Task.

## Dependencies

- 1874428 - Investigate Angular-compatible web packages for manipulating Excel data.
- 1878698 - Security approval for the web-hosting approach.
- 1869308 and its Report Management stories - final navigation and template-selection contract.
- Existing Planning Space authorization, tenant-resolution, report-template, and editor-host services.
