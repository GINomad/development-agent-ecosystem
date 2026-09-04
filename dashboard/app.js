const token = document.documentElement.dataset.sessionToken;
const activity = document.querySelector('#activity');
const repositoryOptions = document.querySelector('#repositoryOptions');
const repositorySummary = document.querySelector('#repositorySummary');
const agentLabels = {
  orchestrator: 'Workflow Orchestrator',
  knowledge_keeper: 'Knowledge Keeper',
  requirements_analyst: 'Requirements Analyst',
  developer: 'Developer',
  reviewer: 'Reviewer',
  review_verifier: 'Review Verifier',
  pipeline_monitor: 'Pipeline Monitor',
  health_check: 'Health Check'
};
const agentRequiredArtifacts = {};
let mode = 'manual';
let taskFilter = 'active';
let selectedTaskId = null;
let selectedTask = null;
let selectedArtifactName = null;
let selectedAgentId = null;
let selectedOutcomeAgentId = null;
let selectedOutcomeArtifactName = null;
let agentLogRequestInFlight = false;
let agentLogRefreshSeconds = 30;
let taskRefreshInFlight = false;
let taskStateRevision = 0;
let schedulerState = { capacity: 0, activeTaskCount: 0, queuedTaskCount: 0 };
let reviewDiffIndex = null;
let selectedDiffRepositoryId = null;
let selectedDiffFilePath = null;
let selectedDiffLine = null;
let reviewDiffScope = 'reviewed-commit';
let reviewDiffRequestInFlight = false;
let reviewDiffReloadPending = false;
let reviewerFeedback = null;
let reviewVerification = null;
let reviewArtifactSha256 = '';
let reviewVerificationStale = false;
let reviewerDecisions = [];
let reviewerTechDebtItems = [];
let reviewerFeedbackRequestInFlight = false;
const agentCommentDrafts = new Map();

function log(value) {
  const text = typeof value === 'string' ? value : JSON.stringify(value, null, 2);
  activity.textContent = `[${new Date().toLocaleTimeString()}] ${text}\n\n${activity.textContent}`;
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      'X-Ecosystem-Token': token,
      ...(options.headers || {})
    }
  });
  const body = await response.json();
  if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`);
  return body;
}

function selectedRepositoryIds() {
  return Array.from(repositoryOptions.querySelectorAll('input[type="checkbox"]:checked'), input => input.value);
}

function updateRepositorySummary() {
  const checked = Array.from(repositoryOptions.querySelectorAll('input[type="checkbox"]:checked'));
  if (!checked.length) repositorySummary.textContent = 'Select repositories';
  else if (checked.length === 1) repositorySummary.textContent = checked[0].dataset.label;
  else repositorySummary.textContent = `${checked.length} repositories selected`;
}

function payloadBase() {
  const repositoryIds = selectedRepositoryIds();
  return {
    mode,
    repositoryIds,
    repositoryId: repositoryIds[0] || '',
    taskSelector: document.querySelector('#taskSelector').value.trim(),
    taskId: document.querySelector('#taskId').value.trim(),
    instruction: document.querySelector('#instruction').value.trim()
  };
}

function taskViewGuard(task = selectedTask) {
  if (!task) throw new Error('Select a current task view first.');
  return {
    expectedRevision: task.revision ?? null,
    runId: task.executionRunId || '',
    leaseId: task.workspaceLeaseId || ''
  };
}

function formatDate(value) {
  if (!value) return 'not reported';
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString();
}

function statusClass(value) {
  return `status-${String(value || 'unknown').replaceAll('_', '-')}`;
}

function agentDraftKey(taskId = selectedTaskId, agentId = selectedAgentId) {
  return taskId && agentId ? `${taskId}:${agentId}` : '';
}

function setAgentActionStatus(message, state = '') {
  const status = document.querySelector('#agentActionStatus');
  status.textContent = message;
  status.dataset.state = state;
}

async function loadExternalReviews() {
  const list = document.querySelector('#externalReviewList');
  const summary = document.querySelector('#externalReviewSummary');
  list.textContent = 'Loading active pull requests...';
  const result = await api('/api/external-reviews');
  const pullRequests = Array.isArray(result.activePullRequests) ? result.activePullRequests : [];
  list.replaceChildren();
  summary.textContent = `${pullRequests.length} active pull request${pullRequests.length === 1 ? '' : 's'} - updated ${formatDate(result.generatedAtUtc)}`;
  if (!pullRequests.length) {
    list.textContent = 'No active authored or assigned pull requests were found by Review Monitor.';
    return;
  }
  pullRequests.forEach(pullRequest => {
    const item = document.createElement('article');
    item.className = 'external-review-item';
    const heading = document.createElement('div');
    heading.className = 'external-review-heading';
    const title = document.createElement('strong');
    title.textContent = `${pullRequest.repositoryName} PR ${pullRequest.pullRequestId}: ${pullRequest.title}`;
    const status = document.createElement('span');
    status.className = `mini-status ${statusClass(pullRequest.reviewStatus)}`;
    status.textContent = String(pullRequest.reviewStatus || 'not-reviewed').replaceAll('-', ' ');
    heading.append(title, status);
    const meta = document.createElement('small');
    meta.textContent = `${pullRequest.repositoryId} - commit ${pullRequest.sourceCommit || 'not reported'}`;
    const actions = document.createElement('div');
    actions.className = 'external-review-actions';
    if (pullRequest.pullRequestUrl) {
      const azureLink = document.createElement('a');
      azureLink.className = 'button secondary compact-button';
      azureLink.href = pullRequest.pullRequestUrl;
      azureLink.target = '_blank';
      azureLink.rel = 'noopener noreferrer';
      azureLink.textContent = 'Open Azure PR';
      actions.append(azureLink);
    }
    if (pullRequest.reportUrl) {
      const reportLink = document.createElement('a');
      reportLink.className = 'button primary compact-button';
      reportLink.href = pullRequest.reportUrl;
      reportLink.target = '_blank';
      reportLink.rel = 'noopener noreferrer';
      reportLink.textContent = 'Open HTML review';
      actions.append(reportLink);
    } else {
      const pending = document.createElement('span');
      pending.className = 'external-review-pending';
      pending.textContent = 'HTML review is not available yet.';
      actions.append(pending);
    }
    item.append(heading, meta, actions);
    list.append(item);
  });
}

async function selectReviewTab(tab) {
  const external = tab === 'external';
  document.querySelector('#localReviewWorkspace').classList.toggle('hidden', external);
  document.querySelector('#externalReviewWorkspace').classList.toggle('hidden', !external);
  document.querySelectorAll('[data-review-tab]').forEach(button => button.classList.toggle('active', button.dataset.reviewTab === tab));
  if (external) await loadExternalReviews();
}

function renderTaskList(tasks) {
  tasks = Array.isArray(tasks) ? tasks : [];
  const list = document.querySelector('#taskList');
  list.replaceChildren();
  if (!tasks.length) {
    list.className = 'task-list empty';
    list.textContent = taskFilter === 'active' ? 'No active tasks.' : 'No persisted tasks.';
    selectedTaskId = null;
    closeAgentLog();
    renderEmptyTaskDetail();
    return;
  }
  list.className = 'task-list';
  if (!selectedTaskId || !tasks.some(item => item.taskId === selectedTaskId)) selectedTaskId = tasks[0].taskId;
  tasks.forEach(item => {
    const button = document.createElement('button');
    button.className = `tracked-task ${item.taskId === selectedTaskId ? 'selected' : ''}`;
    button.type = 'button';
    const heading = document.createElement('span');
    heading.className = 'tracked-task-heading';
    const id = document.createElement('strong');
    id.textContent = item.taskId;
    const badge = document.createElement('span');
    badge.className = `mini-status ${statusClass(item.status)}`;
    badge.textContent = item.status;
    heading.append(id, badge);
    const selector = document.createElement('span');
    selector.className = 'tracked-task-selector';
    selector.textContent = item.selector;
    const meta = document.createElement('span');
    meta.className = 'tracked-task-meta';
    const scheduling = item.scheduler || {};
    const slotText = item.status === 'queued' && scheduling.queuePosition ? `queue #${scheduling.queuePosition}` : scheduling.lease ? `lease ${scheduling.lease.lifecycle || 'active'}` : 'no active lease';
    meta.textContent = `${item.currentStage || 'no stage'} · ${slotText} · ${formatDate(item.updatedAtUtc)}`;
    button.append(heading, selector, meta);
    button.addEventListener('click', async () => {
      if (selectedTaskId !== item.taskId) {
        closeAgentLog();
        closeAgentOutcome();
        closeReviewDiff();
      }
      // Task polling can already be in flight. Loading the selected detail
      // directly keeps a user selection responsive instead of dropping it
      // behind the polling guard in loadTaskList.
      selectedTaskId = item.taskId;
      const selectedRevision = ++taskStateRevision;
      try {
        await loadTaskDetail(item.taskId, selectedRevision);
      } catch (error) {
        log(`Error: ${error.message}`);
      } finally {
        void loadTaskList({ silent: true });
      }
    });
    list.append(button);
  });
}

function renderEmptyTaskDetail() {
  selectedTask = null;
  closeArtifactViewer();
  closeAgentLog();
  closeAgentOutcome();
  closeReviewDiff();
  document.querySelector('#taskDetailEmpty').classList.remove('hidden');
  document.querySelector('#taskDetailContent').classList.add('hidden');
}

function renderTaskDetail(task) {
  selectedTask = task;
  document.querySelector('#taskDetailEmpty').classList.add('hidden');
  document.querySelector('#taskDetailContent').classList.remove('hidden');
  document.querySelector('#selectedTaskId').textContent = task.taskId;
  document.querySelector('#selectedTaskTitle').textContent = task.selector;
  const status = document.querySelector('#selectedTaskStatus');
  status.className = `task-status ${statusClass(task.status)}`;
  status.textContent = task.status;
  const taskRepositoryIds = Array.isArray(task.repositoryIds) && task.repositoryIds.length ? task.repositoryIds : [task.repositoryId].filter(Boolean);
  const scheduling = task.scheduler || {};
  const queueText = task.status === 'queued' && scheduling.queuePosition ? ` · queue #${scheduling.queuePosition}` : '';
  document.querySelector('#selectedTaskMeta').textContent = `${taskRepositoryIds.join(', ') || 'repositories not recorded'} · stage: ${task.currentStage || 'not reported'}${queueText} · updated ${formatDate(task.updatedAtUtc)}`;
  document.querySelector('#selectedTaskMessage').textContent = task.lastMessage || 'No status message has been recorded.';
  const lease = scheduling.lease;
  const controllerText = lease?.controllerProcessId ? ` · controller PID ${lease.controllerProcessId}` : '';
  const heartbeatText = lease?.heartbeatAtUtc ? ` · heartbeat ${formatDate(lease.heartbeatAtUtc)}` : '';
  document.querySelector('#taskLeaseSummary').textContent = lease ? `run ${lease.runId || task.executionRunId || 'unknown'} · lease ${lease.leaseId || task.workspaceLeaseId || 'unknown'} · ${lease.lifecycle || 'active'}${controllerText}${heartbeatText}` : (task.status === 'queued' ? `waiting for slot ${scheduling.queuePosition || '?'}` : 'no active lease');
  const workspaceList = document.querySelector('#taskWorkspaceInfo');
  workspaceList.replaceChildren();
  const taskWorkspaces = Array.isArray(task.workspaces) ? task.workspaces : [];
  if (!taskWorkspaces.length) {
    const emptyWorkspace = document.createElement('p');
    emptyWorkspace.className = 'hint';
    emptyWorkspace.textContent = task.status === 'queued' ? 'Clones will be provisioned after scheduler admission.' : 'No task clone manifest has been recorded yet.';
    workspaceList.append(emptyWorkspace);
  } else {
    taskWorkspaces.forEach(workspace => {
      const card = document.createElement('article');
      card.className = 'task-workspace-card';
      const title = document.createElement('strong');
      title.textContent = workspace.repositoryId || 'repository';
      const lifecycle = document.createElement('span');
      lifecycle.className = `mini-status ${statusClass(workspace.lifecycle)}`;
      lifecycle.textContent = workspace.lifecycle || 'unknown';
      const path = document.createElement('code');
      path.textContent = workspace.path || 'path not recorded';
      const branch = document.createElement('small');
      branch.textContent = `${workspace.branch || 'branch not recorded'} · base ${(workspace.baseSha || '').slice(0, 12) || 'unknown'}`;
      card.append(title, lifecycle, path, branch);
      workspaceList.append(card);
    });
  }

  const openQuestions = Array.isArray(task.openQuestions) ? task.openQuestions : [];
  const inputPanel = document.querySelector('#inputRequiredPanel');
  const questionList = document.querySelector('#openQuestions');
  const questionTarget = document.querySelector('#taskQuestionTarget');
  const selectedQuestionTarget = questionTarget.value;
  inputPanel.classList.toggle('hidden', !openQuestions.length);
  questionList.replaceChildren();
  questionTarget.replaceChildren(new Option('General workflow instruction', ''));
  openQuestions.forEach(question => {
    const item = document.createElement('article');
    item.className = 'open-question';
    const agent = document.createElement('strong');
    agent.textContent = agentLabels[question.actor] || question.actor || 'Agent';
    const text = document.createElement('p');
    text.textContent = question.summary;
    const time = document.createElement('small');
    time.textContent = formatDate(question.timestampUtc);
    const answer = document.createElement('button');
    answer.type = 'button';
    answer.className = 'text-button';
    answer.textContent = 'Answer this question';
    answer.addEventListener('click', () => {
      questionTarget.value = question.eventId;
      document.querySelector('#taskInterventionPanel').open = true;
      document.querySelector('#taskComment').focus();
    });
    item.append(agent, text, time, answer);
    questionList.append(item);
    questionTarget.append(new Option(`${agent.textContent}: ${question.summary}`, question.eventId));
  });
  if (openQuestions.some(question => question.eventId === selectedQuestionTarget)) questionTarget.value = selectedQuestionTarget;

  const agentGrid = document.querySelector('#agentStatusGrid');
  agentGrid.replaceChildren();
  Object.entries(agentLabels).forEach(([id, label]) => {
    const state = task.agentStatuses?.[id] || { status: 'pending', message: '', updatedAtUtc: null };
    const card = document.createElement('article');
    card.className = `agent-state ${statusClass(state.status)} ${selectedAgentId === id ? 'selected' : ''} ${selectedOutcomeAgentId === id ? 'outcome-selected' : ''}`;
    card.dataset.agentId = id;
    const logButton = document.createElement('button');
    logButton.type = 'button';
    logButton.className = 'agent-state-main';
    logButton.setAttribute('aria-label', `Open live activity for ${label}`);
    const top = document.createElement('div');
    top.className = 'agent-state-top';
    const name = document.createElement('strong');
    name.textContent = label;
    const badge = document.createElement('span');
    const unreadCommentCount = Number(state.unreadCommentCount) || 0;
    badge.textContent = unreadCommentCount ? state.status + ' - ' + unreadCommentCount + ' new' : state.status;
    top.append(name, badge);
    const message = document.createElement('p');
    message.textContent = state.message || 'No activity recorded.';
    const time = document.createElement('small');
    const modelRoute = state.modelRoute;
    time.textContent = formatDate(state.updatedAtUtc) + (modelRoute ? ` - ${modelRoute.complexity}: ${modelRoute.model} / ${modelRoute.reasoningEffort}` : '');
    logButton.append(top, message, time);
    logButton.addEventListener('click', () => openAgentLog(id));
    const outcomeButton = document.createElement('button');
    outcomeButton.type = 'button';
    outcomeButton.className = 'agent-outcome-button';
    outcomeButton.textContent = 'View outcome';
    outcomeButton.addEventListener('click', () => openAgentOutcome(id));
    card.append(logButton, outcomeButton);
    agentGrid.append(card);
  });
  if (selectedOutcomeAgentId) renderAgentOutcome();

  const events = Array.isArray(task.events) ? task.events : [];
  const timeline = document.querySelector('#taskTimeline');
  timeline.replaceChildren();
  if (!events.length) timeline.textContent = 'No events recorded.';
  events.forEach(event => {
    const item = document.createElement('article');
    item.className = `timeline-event event-${event.type}`;
    const top = document.createElement('div');
    const type = document.createElement('strong');
    type.textContent = event.type;
    const time = document.createElement('time');
    time.textContent = formatDate(event.timestampUtc);
    top.append(type, time);
    const summary = document.createElement('p');
    summary.textContent = event.summary;
    const actor = document.createElement('small');
    actor.textContent = `by ${event.actor}`;
    item.append(top, summary, actor);
    timeline.append(item);
  });

  const taskArtifactItems = Array.isArray(task.artifacts) ? task.artifacts : [];
  const artifacts = document.querySelector('#taskArtifacts');
  artifacts.replaceChildren();
  if (!taskArtifactItems.length) artifacts.textContent = 'No artifacts produced yet.';
  taskArtifactItems.forEach(artifact => {
    const item = document.createElement('button');
    item.type = 'button';
    item.className = 'artifact-item';
    const name = document.createElement('strong');
    name.textContent = artifact.name;
    const meta = document.createElement('span');
    meta.textContent = `${artifact.length} bytes - ${formatDate(artifact.lastWriteTimeUtc)}`;
    item.append(name, meta);
    item.addEventListener('click', () => openArtifact(artifact.name));
    artifacts.append(item);
  });
  if (selectedArtifactName && !taskArtifactItems.some(artifact => artifact.name === selectedArtifactName)) closeArtifactViewer();

  const resume = document.querySelector('#resumeTask');
  resume.disabled = task.status === 'running';
  resume.textContent = task.status === 'running' ? 'Workflow is running' : 'Resume workflow';
  document.querySelector('#resumeElevatedWorkflow').disabled = task.status === 'running';
  document.querySelector('#stopWorkflow').disabled = task.status !== 'running';
  document.querySelector('#restartAgentWithComment').disabled = task.status === 'running';
  document.querySelector('#sendAndRestartReviewTarget').disabled = task.status === 'running';
  const closeTaskButton = document.querySelector('#closeTaskManually');
  closeTaskButton.disabled = task.status === 'running' || task.status === 'completed';
  document.querySelector('#manualClosePanel').classList.toggle('hidden', task.status === 'completed');
  document.querySelector('#reopenTaskPanel').classList.toggle('hidden', task.status !== 'completed');
  const executionPolicyNotice = document.querySelector('#executionPolicyNotice');
  const policyBlocked = /CreateProcessWithLogonW|error\s*1260|Windows sandbox/i.test(`${task.lastMessage || ''} ${task.agentStatuses?.knowledge_keeper?.message || ''}`);
  executionPolicyNotice.classList.toggle('hidden', !policyBlocked);
  const elevated = document.querySelector('#approveElevatedRecovery');
  const healthStatus = task.agentStatuses?.health_check?.status;
  elevated.disabled = !['waiting', 'failed'].includes(healthStatus) || !taskArtifactItems.some(artifact => artifact.name.startsWith('agent-failure-'));
}

function closeArtifactViewer() {
  selectedArtifactName = null;
  const viewer = document.querySelector('#artifactViewer');
  if (viewer) viewer.classList.add('hidden');
}

async function openArtifact(name) {
  if (!selectedTaskId) throw new Error('Select a task first.');
  selectedArtifactName = name;
  const viewer = document.querySelector('#artifactViewer');
  const content = document.querySelector('#artifactContent');
  viewer.classList.remove('hidden');
  document.querySelector('#artifactTitle').textContent = name;
  document.querySelector('#artifactMeta').textContent = 'Loading preview...';
  content.textContent = '';
  try {
    const result = await api(`/api/tasks/${encodeURIComponent(selectedTaskId)}/artifacts/${encodeURIComponent(name)}`);
    const artifact = result.artifact;
    if (selectedArtifactName !== name) return;
    document.querySelector('#artifactMeta').textContent = `${artifact.length} bytes - ${formatDate(artifact.lastWriteTimeUtc)}${artifact.truncated ? ' - preview limited to 1 MiB' : ''}`;
    content.textContent = artifact.content || '(empty artifact)';
  } catch (error) {
    document.querySelector('#artifactMeta').textContent = 'Preview unavailable';
    content.textContent = error.message;
    log(`Error: ${error.message}`);
  }
}

function closeAgentOutcome() {
  selectedOutcomeAgentId = null;
  selectedOutcomeArtifactName = null;
  const panel = document.querySelector('#agentOutcomePanel');
  if (panel) panel.classList.add('hidden');
  document.querySelector('#openReviewDiff').classList.add('hidden');
  document.querySelectorAll('.agent-state.outcome-selected').forEach(card => card.classList.remove('outcome-selected'));
}

function appendOutcomeList(parent, values, emptyText = '') {
  const items = Array.isArray(values) ? values.filter(value => String(value || '').trim()) : [];
  if (!items.length) {
    if (emptyText) {
      const empty = document.createElement('p');
      empty.className = 'requirements-empty';
      empty.textContent = emptyText;
      parent.append(empty);
    }
    return;
  }
  const list = document.createElement('ul');
  items.forEach(value => {
    const item = document.createElement('li');
    item.textContent = String(value);
    list.append(item);
  });
  parent.append(list);
}

function requirementsPresentation(result) {
  if (result?.humanReadable) return result.humanReadable;
  const legacyPlan = Array.isArray(result?.plan) ? result.plan : [];
  return {
    title: `Requirements analysis for ${result?.taskId || 'task'}`,
    objective: result?.summary || 'No objective was published.',
    legacyDerived: true,
    requirements: (Array.isArray(result?.requirements) ? result.requirements : []).map(requirement => ({
      id: requirement.id,
      title: requirement.id,
      description: requirement.text,
      acceptanceCriteria: [],
      evidence: requirement.evidence,
      status: requirement.status
    })),
    workflow: legacyPlan.map((step, index) => ({
      order: index + 1,
      title: step.id || `Step ${index + 1}`,
      description: step.action,
      owner: 'Developer',
      outputs: [],
      gate: (step.validation || []).join('; ') || 'No validation gate was published.'
    })),
    implementationPlan: legacyPlan.map((step, index) => ({
      order: index + 1,
      title: step.id || `Step ${index + 1}`,
      description: step.action,
      requirementIds: step.requirementIds,
      validation: step.validation,
      status: step.status
    }))
  };
}

function renderRequirementsOutcome(rawContent) {
  let result;
  try {
    result = JSON.parse(rawContent);
  } catch {
    return false;
  }
  const presentation = requirementsPresentation(result);
  if (!presentation || !Array.isArray(presentation.requirements)) return false;
  const content = document.querySelector('#agentOutcomeContent');
  const documentView = document.createElement('article');
  documentView.className = 'requirements-outcome';

  const heading = document.createElement('header');
  const title = document.createElement('h5');
  title.textContent = presentation.title || 'Requirements analysis';
  const objective = document.createElement('p');
  objective.textContent = presentation.objective || result.summary || '';
  heading.append(title, objective);
  if (presentation.legacyDerived) {
    const legacy = document.createElement('p');
    legacy.className = 'requirements-legacy-note';
    legacy.textContent = 'Legacy outcome: this readable view was derived from the persisted machine fields.';
    heading.append(legacy);
  }
  documentView.append(heading);

  const requirementsSection = document.createElement('section');
  const requirementsTitle = document.createElement('h6');
  requirementsTitle.textContent = 'Requirements and acceptance criteria';
  requirementsSection.append(requirementsTitle);
  presentation.requirements.forEach(requirement => {
    const card = document.createElement('article');
    card.className = 'requirements-card';
    const cardHeading = document.createElement('div');
    cardHeading.className = 'requirements-card-heading';
    const name = document.createElement('strong');
    name.textContent = `${requirement.id || 'Requirement'} · ${requirement.title || requirement.description || ''}`;
    const status = document.createElement('span');
    status.className = `requirements-status ${statusClass(requirement.status)}`;
    status.textContent = requirement.status || 'unknown';
    cardHeading.append(name, status);
    const description = document.createElement('p');
    description.textContent = requirement.description || '';
    card.append(cardHeading, description);
    const criteriaTitle = document.createElement('b');
    criteriaTitle.textContent = requirement.acceptanceCriteria?.length ? 'Acceptance criteria' : 'Acceptance criteria not separately published';
    card.append(criteriaTitle);
    appendOutcomeList(card, requirement.acceptanceCriteria);
    if (requirement.evidence?.length) {
      const evidenceTitle = document.createElement('b');
      evidenceTitle.textContent = 'Evidence';
      card.append(evidenceTitle);
      appendOutcomeList(card, requirement.evidence);
    }
    requirementsSection.append(card);
  });
  documentView.append(requirementsSection);

  const workflowSection = document.createElement('section');
  const workflowTitle = document.createElement('h6');
  workflowTitle.textContent = 'Expected workflow';
  workflowSection.append(workflowTitle);
  (presentation.workflow || []).forEach(step => {
    const item = document.createElement('article');
    item.className = 'requirements-step';
    const name = document.createElement('strong');
    name.textContent = `${step.order}. ${step.title}`;
    const owner = document.createElement('span');
    owner.textContent = `Owner: ${step.owner}`;
    const description = document.createElement('p');
    description.textContent = step.description;
    const gate = document.createElement('p');
    gate.className = 'requirements-gate';
    gate.textContent = `Gate: ${step.gate}`;
    item.append(name, owner, description, gate);
    appendOutcomeList(item, step.outputs);
    workflowSection.append(item);
  });
  if (!(presentation.workflow || []).length) appendOutcomeList(workflowSection, [], 'No workflow was published.');
  documentView.append(workflowSection);

  const planSection = document.createElement('section');
  const planTitle = document.createElement('h6');
  planTitle.textContent = 'Implementation plan';
  planSection.append(planTitle);
  (presentation.implementationPlan || []).forEach(step => {
    const item = document.createElement('article');
    item.className = 'requirements-step';
    const name = document.createElement('strong');
    name.textContent = `${step.order}. ${step.title}`;
    const status = document.createElement('span');
    status.className = `requirements-status ${statusClass(step.status)}`;
    status.textContent = step.status || 'unknown';
    const description = document.createElement('p');
    description.textContent = step.description;
    item.append(name, status, description);
    appendOutcomeList(item, (step.requirementIds || []).map(id => `Requirement: ${id}`));
    appendOutcomeList(item, step.validation);
    planSection.append(item);
  });
  if (!(presentation.implementationPlan || []).length) appendOutcomeList(planSection, [], 'No implementation is authorized or planned for this outcome.');
  documentView.append(planSection);
  content.replaceChildren(documentView);
  return true;
}

function renderRawAgentOutcome(rawContent) {
  const content = document.querySelector('#agentOutcomeContent');
  const pre = document.createElement('pre');
  pre.textContent = rawContent || '(empty outcome artifact)';
  content.replaceChildren(pre);
}

async function loadAgentOutcomeArtifact(name) {
  if (!selectedTaskId || !selectedOutcomeAgentId) return;
  const taskId = selectedTaskId;
  const agentId = selectedOutcomeAgentId;
  selectedOutcomeArtifactName = name;
  const content = document.querySelector('#agentOutcomeContent');
  document.querySelector('#agentOutcomeArtifactMeta').textContent = `Loading ${name}...`;
  content.textContent = '';
  try {
    const result = await api(`/api/tasks/${encodeURIComponent(taskId)}/artifacts/${encodeURIComponent(name)}`);
    if (selectedTaskId !== taskId || selectedOutcomeAgentId !== agentId || selectedOutcomeArtifactName !== name) return;
    const artifact = result.artifact;
    document.querySelector('#agentOutcomeArtifactMeta').textContent = `${artifact.name} - ${artifact.length} bytes - updated ${formatDate(artifact.lastWriteTimeUtc)}${artifact.truncated ? ' - preview limited to 1 MiB' : ''}`;
    const rendered = agentId === 'requirements_analyst' && name === 'requirements-analysis.json'
      ? renderRequirementsOutcome(artifact.content || '')
      : false;
    if (!rendered) renderRawAgentOutcome(artifact.content || '');
    document.querySelectorAll('.agent-outcome-artifact').forEach(button => button.classList.toggle('selected', button.dataset.name === name));
  } catch (error) {
    if (selectedTaskId === taskId && selectedOutcomeAgentId === agentId) {
      document.querySelector('#agentOutcomeArtifactMeta').textContent = 'Outcome artifact unavailable';
      renderRawAgentOutcome(error.message);
    }
  }
}

function renderAgentOutcome() {
  if (!selectedTask || !selectedOutcomeAgentId) return;
  const agentId = selectedOutcomeAgentId;
  const label = agentLabels[agentId] || agentId;
  const state = selectedTask.agentStatuses?.[agentId] || { status: 'pending', message: '', updatedAtUtc: null };
  const requiredNames = Array.isArray(agentRequiredArtifacts[agentId]) ? agentRequiredArtifacts[agentId] : [];
  const taskArtifacts = Array.isArray(selectedTask.artifacts) ? selectedTask.artifacts : [];
  const availableNames = requiredNames.filter(name => taskArtifacts.some(artifact => artifact.name === name));
  document.querySelector('#agentOutcomePanel').classList.remove('hidden');
  document.querySelector('#agentOutcomeTitle').textContent = `${label} outcome`;
  const modelRoute = state.modelRoute;
  document.querySelector('#agentOutcomeMeta').textContent = `${state.status || 'pending'} - updated ${formatDate(state.updatedAtUtc)}` +
    (modelRoute ? ` - ${modelRoute.complexity}: ${modelRoute.model} / ${modelRoute.reasoningEffort}` : '');
  document.querySelector('#agentOutcomeSummary').textContent = state.message || 'No persisted outcome summary is available.';
  document.querySelector('#openReviewDiff').classList.toggle('hidden', agentId !== 'reviewer');
  document.querySelectorAll('.agent-state').forEach(card => card.classList.toggle('outcome-selected', card.dataset.agentId === agentId));
  const list = document.querySelector('#agentOutcomeArtifacts');
  list.replaceChildren();
  if (!requiredNames.length) {
    list.textContent = 'This role has no configured outcome artifacts.';
  }
  requiredNames.forEach(name => {
    const available = availableNames.includes(name);
    const item = document.createElement(available ? 'button' : 'span');
    item.className = `agent-outcome-artifact ${available ? '' : 'missing'}`;
    item.textContent = available ? name : `${name} - not produced`;
    if (available) {
      item.type = 'button';
      item.dataset.name = name;
      item.classList.toggle('selected', selectedOutcomeArtifactName === name);
      item.addEventListener('click', () => loadAgentOutcomeArtifact(name));
    }
    list.append(item);
  });
  const preferredName = availableNames.includes(selectedOutcomeArtifactName) ? selectedOutcomeArtifactName : availableNames.at(-1);
  if (preferredName && preferredName !== selectedOutcomeArtifactName) {
    loadAgentOutcomeArtifact(preferredName);
  } else if (!preferredName) {
    selectedOutcomeArtifactName = null;
    document.querySelector('#agentOutcomeArtifactMeta').textContent = state.status === 'running' ? 'Outcome is still in progress.' : 'No configured outcome artifact was produced.';
    document.querySelector('#agentOutcomeContent').replaceChildren();
  }
}

function openAgentOutcome(agentId) {
  selectedOutcomeAgentId = agentId;
  selectedOutcomeArtifactName = null;
  renderAgentOutcome();
  document.querySelector('#agentOutcomePanel').scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function diffProperty(value, pascalName, camelName) {
  if (!value) return null;
  return value[pascalName] ?? value[camelName] ?? null;
}

function closeReviewDiff() {
  resetReviewDiffCommentEditor();
  reviewDiffIndex = null;
  selectedDiffRepositoryId = null;
  selectedDiffFilePath = null;
  selectedDiffLine = null;
  reviewerFeedback = null;
  reviewVerification = null;
  reviewArtifactSha256 = '';
  reviewVerificationStale = false;
  reviewerDecisions = [];
  reviewerTechDebtItems = [];
  const panel = document.querySelector('#reviewDiffPanel');
  if (panel) panel.classList.add('hidden');
  const lines = document.querySelector('#reviewDiffLines');
  if (lines) lines.replaceChildren();
  const files = document.querySelector('#reviewDiffFiles');
  if (files) files.replaceChildren();
  const selection = document.querySelector('#reviewDiffSelection');
  if (selection) selection.textContent = 'Select a diff line to comment.';
}

function setReviewDiffCommentStatus(message, state = '') {
  const status = document.querySelector('#reviewDiffCommentStatus');
  status.textContent = message;
  status.dataset.state = state;
}

function setReviewerFeedbackStatus(message, state = '') {
  const status = document.querySelector('#reviewFeedbackStatus');
  status.textContent = message;
  status.dataset.state = state;
}

function latestReviewerDecision(findingId) {
  const normalizedId = String(findingId || '').toLowerCase();
  let latest = null;
  reviewerDecisions.forEach(decision => {
    if (String(decision?.findingId || '').toLowerCase() !== normalizedId) return;
    if (String(decision?.reviewedRevision || '') !== String(reviewerFeedback?.reviewedRevision || '')) return;
    if (String(decision?.reviewArtifactSha256 || '') !== reviewArtifactSha256) return;
    const currentTimestamp = Date.parse(latest?.decidedAtUtc || latest?.decidedAt || '') || 0;
    const candidateTimestamp = Date.parse(decision?.decidedAtUtc || decision?.decidedAt || '') || 0;
    if (!latest || candidateTimestamp >= currentTimestamp) latest = decision;
  });
  return latest;
}

function isReviewerItemBypassedAsDebt(item) {
  const findingId = String(item?.id || '');
  const decision = latestReviewerDecision(findingId);
  if (String(decision?.decision || '').toLowerCase() !== 'bypassed') return false;
  return reviewerTechDebtItems.some(debt =>
    String(debt?.sourceFindingId || '').toLowerCase() === findingId.toLowerCase()
      && String(debt?.status || '').toLowerCase() === 'open'
      && String(debt?.reviewArtifactSha256 || '') === reviewArtifactSha256
  );
}

function reviewVerificationFor(findingId) {
  return (reviewVerification?.findingVerifications || [])
    .find(item => String(item?.findingId || '').toLowerCase() === String(findingId || '').toLowerCase()) || null;
}

function findingLifecycleFor(findingId) {
  return (reviewerFeedback?.findingLifecycle || [])
    .find(item => String(item?.findingId || '').toLowerCase() === String(findingId || '').toLowerCase()) || null;
}

function activeReviewerSummary(result) {
  const summary = String(result?.summary || '').trim();
  if (!summary) return '';
  const hiddenFindingIds = [...(result?.findings || []), ...(result?.agentProcessFindings || [])]
    .filter(item => isReviewerItemBypassedAsDebt(item) || String(reviewVerificationFor(item?.id)?.verdict || '') === 'rejected')
    .map(item => String(item?.id || '').toLowerCase())
    .filter(Boolean);
  if (!hiddenFindingIds.length) return summary;
  return summary
    .split(/\s+(?=(?:fact|inference|conflict):)/i)
    .filter(sentence => !hiddenFindingIds.some(id => sentence.toLowerCase().includes(id)))
    .join(' ')
    .trim();
}

function reviewerFeedbackItems(result) {
  const items = [];
  const summary = activeReviewerSummary(result);
  if (summary) {
    items.push({ id: 'REVIEW-SUMMARY', kind: 'summary', severity: 'info', summary });
  }
  const collections = [
    ['finding', result?.findings],
    ['process suggestion', result?.agentProcessFindings],
    ['held-scope violation', result?.heldScopeViolations]
  ];
  collections.forEach(([kind, values]) => {
    if (!Array.isArray(values)) return;
    values.forEach((value, index) => {
      const item = value && typeof value === 'object' ? value : { summary: String(value) };
      const itemId = String(item.id || `${kind.toUpperCase().replaceAll(' ', '-')}-${index + 1}`);
      const verification = reviewVerificationFor(itemId);
      const lifecycle = findingLifecycleFor(itemId);
      const normalizedItem = {
        ...item,
        id: itemId,
        kind,
        verificationVerdict: verification?.verdict || '',
        verificationNotes: verification?.notes || '',
        lifecycleStatus: lifecycle?.status || ''
      };
      if (!isReviewerItemBypassedAsDebt(normalizedItem)) items.push(normalizedItem);
    });
  });
  return items;
}

function normalizeReviewPath(value) {
  return String(value || '').replaceAll('\\', '/').replace(/^\.?\//, '').replace(/^[ab]\//, '').toLowerCase();
}

function reviewerCodeLocation(item) {
  const value = item?.codeLocation;
  if (value && typeof value === 'object' && value.filePath) {
    return {
      repositoryId: String(value.repositoryId || ''),
      filePath: String(value.filePath),
      oldLine: Number.isInteger(value.oldLine) ? value.oldLine : null,
      newLine: Number.isInteger(value.newLine) ? value.newLine : null,
      endLine: Number.isInteger(value.endLine) ? value.endLine : null
    };
  }
  const legacy = /^(.*):(\d+)(?:-(\d+))?$/.exec(String(item?.location || '').trim());
  if (!legacy) return null;
  return {
    repositoryId: '',
    filePath: legacy[1],
    oldLine: null,
    newLine: Number(legacy[2]),
    endLine: legacy[3] ? Number(legacy[3]) : null
  };
}

function reviewerItemsForDiffLine(repositoryId, filePath, oldLine, newLine) {
  const normalizedPath = normalizeReviewPath(filePath);
  return reviewerFeedbackItems(reviewerFeedback).filter(item => {
    if (item.kind === 'summary') return false;
    const location = reviewerCodeLocation(item);
    if (!location || normalizeReviewPath(location.filePath) !== normalizedPath) return false;
    if (location.repositoryId && location.repositoryId !== repositoryId) return false;
    const line = location.newLine ?? location.oldLine;
    const candidate = location.newLine != null ? newLine : oldLine;
    return line != null && candidate != null && candidate >= line && candidate <= (location.endLine ?? line);
  });
}

function createInlineReviewerComment(item) {
  const card = document.createElement('article');
  card.className = 'review-inline-comment';
  const header = document.createElement('div');
  header.className = 'review-inline-comment-header';
  const identity = document.createElement('span');
  identity.textContent = item.id + ' · ' + item.kind;
  const severity = document.createElement('span');
  severity.textContent = [item.severity, item.category, item.lifecycleStatus, item.verificationVerdict || 'awaiting verification'].filter(Boolean).join(' · ') || 'recorded';
  header.append(identity, severity);
  card.append(header);
  const message = item.title || item.summary || item.evidence || item.message;
  if (message) {
    const paragraph = document.createElement('p');
    paragraph.textContent = String(message);
    card.append(paragraph);
  }
  const correction = item.correctionDirection || item.recommendation || item.suggestion;
  if (correction) {
    const paragraph = document.createElement('p');
    paragraph.textContent = 'Suggested correction: ' + correction;
    card.append(paragraph);
  }
  return card;
}

function parseReviewDiffQuestionSource(event) {
  const lines = String(event?.summary || '').split(/\r?\n/);
  if (lines[0] !== '[Task diff line comment]') return null;
  const value = label => {
    const line = lines.find(candidate => candidate.startsWith(label + ': '));
    return line ? line.slice(label.length + 2) : '';
  };
  const separator = lines.findIndex((line, index) => index > 0 && line === '');
  const parseLine = valueText => valueText && valueText !== 'n/a' ? Number(valueText) : null;
  return {
    repositoryId: value('Repository'),
    filePath: value('File'),
    oldLine: parseLine(value('Old line')),
    newLine: parseLine(value('New line')),
    diffLine: value('Diff line'),
    question: lines.slice(separator >= 0 ? separator + 1 : lines.length).join('\n').trim()
  };
}

function reviewQuestionsForDiffLine(repositoryId, filePath, oldLine, newLine) {
  const normalizedPath = normalizeReviewPath(filePath);
  return allReviewQuestionThreads()
    .filter(thread => {
      const context = thread.context;
      if (!context || context.repositoryId !== repositoryId || normalizeReviewPath(context.filePath) !== normalizedPath) return false;
      return (context.newLine != null && newLine === context.newLine) || (context.newLine == null && context.oldLine != null && oldLine === context.oldLine);
    });
}

function allReviewQuestionThreads() {
  const events = Array.isArray(selectedTask?.events) ? selectedTask.events : [];
  return events
    .filter(event => event?.type === 'review-question-opened')
    .map(questionEvent => {
      const sourceCommentId = Array.isArray(questionEvent.evidence) ? questionEvent.evidence[0] : null;
      const sourceEvent = events.find(event => event?.eventId === sourceCommentId && event?.type === 'user-comment');
      const context = parseReviewDiffQuestionSource(sourceEvent);
      const answer = events.find(event => event?.type === 'review-question-answered' && Array.isArray(event.evidence) && event.evidence.includes(questionEvent.eventId));
      const parentEvidence = Array.isArray(questionEvent.evidence)
        ? questionEvent.evidence.find(item => String(item).startsWith('parent-review-question:'))
        : null;
      const parentQuestionId = parentEvidence ? String(parentEvidence).slice('parent-review-question:'.length) : null;
      return { questionEvent, sourceEvent, context, answer, parentQuestionId };
    })
    .sort((left, right) => String(left.questionEvent.timestampUtc || '').localeCompare(String(right.questionEvent.timestampUtc || '')));
}

async function openReviewQuestionSource(thread) {
  const context = thread.context;
  if (!context) return;
  reviewDiffScope = 'all-task-changes';
  document.querySelector('#reviewDiffScope').value = reviewDiffScope;
  selectedDiffRepositoryId = context.repositoryId;
  selectedDiffFilePath = context.filePath;
  await loadReviewDiff();
  const selector = context.newLine != null
    ? `#reviewDiffLines .diff-line[data-new-line="${context.newLine}"]`
    : `#reviewDiffLines .diff-line[data-old-line="${context.oldLine}"]`;
  const row = document.querySelector(selector);
  if (row) {
    row.scrollIntoView({ block: 'center', behavior: 'smooth' });
    row.focus({ preventScroll: true });
  }
}

async function sendReviewQuestionFollowUp(thread, textarea, buttons, restart) {
  const text = textarea.value.trim();
  if (!text) throw new Error('Enter a follow-up question.');
  const context = thread.context;
  if (!context) throw new Error('The original diff-line context is unavailable.');
  const comment = [
    '[Task diff line comment]',
    'Repository: ' + context.repositoryId,
    'File: ' + context.filePath,
    'Old line: ' + (context.oldLine ?? 'n/a'),
    'New line: ' + (context.newLine ?? 'n/a'),
    'Diff line: ' + context.diffLine,
    '',
    text
  ].join('\n');
  if (comment.length > 4000) throw new Error('Follow-up plus diff context exceeds 4000 characters.');
  if (restart && selectedTask?.status === 'running') throw new Error('Stop the running workflow before restarting Reviewer.');
  buttons.forEach(button => { button.disabled = true; });
  try {
    const saved = await api('/api/tasks/' + encodeURIComponent(selectedTaskId) + '/comments', {
      method: 'POST',
      body: JSON.stringify({
        text: comment,
        targetAgentId: 'reviewer',
        commentKind: 'review-question',
        parentReviewQuestionId: thread.questionEvent.eventId
      })
    });
    let restarted = null;
    if (restart) {
      restarted = await api('/api/tasks/' + encodeURIComponent(selectedTaskId) + '/agents/reviewer/resume', {
        method: 'POST',
        body: JSON.stringify({ elevated: true, ...taskViewGuard() })
      });
    }
    textarea.value = '';
    taskStateRevision += 1;
    await loadTaskDetail(selectedTaskId, taskStateRevision);
    renderReviewerFeedback();
    await loadTaskList({ silent: true });
    setReviewerFeedbackStatus(restart ? 'Follow-up saved and Reviewer restarted.' : 'Follow-up saved for Reviewer.', 'success');
    log({ followUp: saved, restart: restarted });
  } finally {
    buttons.forEach(button => { button.disabled = false; });
  }
}

function renderReviewQuestionThreads() {
  const list = document.querySelector('#reviewQuestionThreadsList');
  const summary = document.querySelector('#reviewQuestionThreadsSummary');
  if (!list || !summary) return;
  const threads = allReviewQuestionThreads();
  const unanswered = threads.filter(thread => !thread.answer).length;
  summary.textContent = threads.length
    ? `${threads.length} question(s); ${unanswered} awaiting answer.`
    : 'No questions have been sent to Reviewer.';
  list.replaceChildren();
  threads.forEach(thread => {
    const context = thread.context;
    const card = document.createElement('article');
    card.className = 'review-question-thread-card ' + (thread.answer ? 'answered' : 'pending');
    const header = document.createElement('div');
    header.className = 'review-question-thread-header';
    const location = document.createElement('strong');
    const line = context?.newLine ?? context?.oldLine;
    const prefix = thread.parentQuestionId ? 'Follow-up · ' : '';
    location.textContent = context ? `${prefix}${context.filePath}:${line ?? '?'}` : 'Reviewer question';
    const status = document.createElement('span');
    status.textContent = thread.answer ? 'answered' : 'awaiting answer';
    header.append(location, status);
    const question = document.createElement('p');
    question.textContent = context?.question || thread.sourceEvent?.summary || '';
    card.append(header, question);
    if (thread.answer) {
      const answer = document.createElement('div');
      answer.className = 'review-question-thread-answer';
      const label = document.createElement('strong');
      label.textContent = 'Reviewer answer';
      const text = document.createElement('p');
      text.textContent = String(thread.answer.summary || '');
      answer.append(label, text);
      card.append(answer);
    }
    if (context) {
      const actions = document.createElement('div');
      actions.className = 'review-question-thread-actions';
      const openButton = document.createElement('button');
      openButton.type = 'button';
      openButton.className = 'button secondary compact-button';
      openButton.textContent = 'Open source line';
      openButton.addEventListener('click', () => openReviewQuestionSource(thread).catch(error => log('Error: ' + error.message)));
      actions.append(openButton);
      if (thread.answer) {
        const textarea = document.createElement('textarea');
        textarea.rows = 2;
        textarea.maxLength = 4000;
        textarea.placeholder = 'Reply to this Reviewer answer...';
        textarea.setAttribute('aria-label', 'Follow-up question to Reviewer');
        const sendButton = document.createElement('button');
        sendButton.type = 'button';
        sendButton.className = 'button primary compact-button';
        sendButton.textContent = 'Send follow-up';
        const restartButton = document.createElement('button');
        restartButton.type = 'button';
        restartButton.className = 'button danger compact-button';
        restartButton.textContent = 'Send and restart Reviewer';
        const buttons = [sendButton, restartButton];
        sendButton.addEventListener('click', () => sendReviewQuestionFollowUp(thread, textarea, buttons, false).catch(error => {
          setReviewerFeedbackStatus(error.message, 'error');
          log('Error: ' + error.message);
        }));
        restartButton.addEventListener('click', () => sendReviewQuestionFollowUp(thread, textarea, buttons, true).catch(error => {
          setReviewerFeedbackStatus(error.message, 'error');
          log('Error: ' + error.message);
        }));
        actions.append(textarea, sendButton, restartButton);
      }
      card.append(actions);
    }
    list.append(card);
  });
}

function createInlineReviewQuestion(thread) {
  const card = document.createElement('article');
  card.className = 'review-inline-question ' + (thread.answer ? 'answered' : 'pending');
  const header = document.createElement('div');
  header.className = 'review-inline-question-header';
  const identity = document.createElement('span');
  identity.textContent = 'Your question to Reviewer';
  const status = document.createElement('span');
  status.textContent = thread.answer ? 'answered' : 'awaiting answer';
  header.append(identity, status);
  const question = document.createElement('p');
  question.textContent = thread.context?.question || thread.sourceEvent?.summary || '';
  card.append(header, question);
  if (thread.answer) {
    const answer = document.createElement('div');
    answer.className = 'review-inline-answer';
    const label = document.createElement('strong');
    label.textContent = 'Reviewer answer';
    const text = document.createElement('p');
    text.textContent = String(thread.answer.summary || '');
    answer.append(label, text);
    card.append(answer);
  }
  return card;
}

function renderInlineReviewerComments() {
  document.querySelectorAll('.review-inline-comment, .review-inline-question').forEach(item => item.remove());
  document.querySelectorAll('#reviewDiffLines .diff-line[data-selectable="true"]').forEach(row => {
    const items = reviewerItemsForDiffLine(
      row.dataset.repositoryId,
      row.dataset.filePath,
      row.dataset.oldLine ? Number(row.dataset.oldLine) : null,
      row.dataset.newLine ? Number(row.dataset.newLine) : null
    );
    let anchor = row.nextElementSibling?.id === 'reviewDiffCommentPanel' ? row.nextElementSibling : row;
    items.forEach(item => {
      const comment = createInlineReviewerComment(item);
      anchor.insertAdjacentElement('afterend', comment);
      anchor = comment;
    });
    const questions = reviewQuestionsForDiffLine(
      row.dataset.repositoryId,
      row.dataset.filePath,
      row.dataset.oldLine ? Number(row.dataset.oldLine) : null,
      row.dataset.newLine ? Number(row.dataset.newLine) : null
    );
    questions.forEach(thread => {
      const question = createInlineReviewQuestion(thread);
      anchor.insertAdjacentElement('afterend', question);
      anchor = question;
    });
  });
}

function requirementTraceabilityItems(result) {
  return Array.isArray(result?.requirementTraceability) ? result.requirementTraceability : [];
}

async function openRequirementCodeReference(reference) {
  const repositoryId = String(reference.repositoryId || selectedDiffRepositoryId || '');
  const filePath = String(reference.filePath || '');
  const line = Number(reference.startLine || reference.newLine || reference.oldLine || 0);
  if (!repositoryId || !filePath) throw new Error('Requirement evidence does not identify a repository and file.');
  await loadReviewDiffFile(repositoryId, filePath);
  const selector = line > 0
    ? `.diff-line[data-new-line="${line}"], .diff-line[data-old-line="${line}"]`
    : '.diff-line[data-selectable="true"]';
  const row = document.querySelector(selector);
  if (!row) throw new Error('The referenced line is not present in the current diff.');
  row.click();
  row.scrollIntoView({ behavior: 'smooth', block: 'center' });
}

function renderRequirementTraceability() {
  const list = document.querySelector('#requirementTraceabilityList');
  const summary = document.querySelector('#requirementTraceabilitySummary');
  list.replaceChildren();
  const items = requirementTraceabilityItems(reviewerFeedback);
  summary.textContent = items.length
    ? `${items.length} requirement mapping(s) recorded by Reviewer.`
    : 'Reviewer has not produced requirement traceability yet.';
  if (!items.length) {
    const empty = document.createElement('p');
    empty.className = 'agent-log-empty';
    empty.textContent = 'Restart Reviewer after the updated review contract is installed to produce requirement-to-code evidence.';
    list.append(empty);
    return;
  }
  items.forEach(item => {
    const card = document.createElement('article');
    card.className = 'requirement-traceability-card';
    const header = document.createElement('div');
    header.className = 'requirement-traceability-card-header';
    const identity = document.createElement('strong');
    identity.textContent = String(item.requirementId || 'Requirement');
    const status = document.createElement('span');
    status.className = 'requirement-traceability-status';
    status.textContent = String(item.implementationStatus || 'unknown').replaceAll('-', ' ');
    header.append(identity, status);
    card.append(header);
    if (item.requirementText) {
      const text = document.createElement('p');
      text.className = 'requirement-traceability-text';
      text.textContent = String(item.requirementText);
      card.append(text);
    }
    const references = Array.isArray(item.codeReferences) ? item.codeReferences : [];
    if (references.length) {
      const referenceList = document.createElement('div');
      referenceList.className = 'requirement-code-references';
      references.forEach(reference => {
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'requirement-code-reference';
        const endLine = reference.endLine && reference.endLine !== reference.startLine ? '-' + reference.endLine : '';
        const symbol = reference.symbol ? ' · ' + reference.symbol : '';
        button.textContent = `${reference.repositoryId || 'repository'} / ${reference.filePath}:${reference.startLine || '?'}${endLine}${symbol}`;
        button.addEventListener('click', async () => {
          try { await openRequirementCodeReference(reference); }
          catch (error) { setReviewerFeedbackStatus(error.message, 'error'); log('Error: ' + error.message); }
        });
        referenceList.append(button);
      });
      card.append(referenceList);
    }
    if (item.notes) {
      const note = document.createElement('p');
      note.className = 'requirement-traceability-note';
      note.textContent = String(item.notes);
      card.append(note);
    }
    list.append(card);
  });
}

function reviewerFeedbackReplies(itemId) {
  const evidenceKey = `review-finding:${itemId}`;
  const events = Array.isArray(selectedTask?.events) ? selectedTask.events : [];
  return events
    .filter(event => event?.type === 'user-comment' && Array.isArray(event.evidence) && event.evidence.includes(evidenceKey))
    .sort((left, right) => String(left.timestampUtc || '').localeCompare(String(right.timestampUtc || '')));
}

function appendReviewerFeedbackField(container, label, value) {
  if (value == null || value === '' || (Array.isArray(value) && !value.length)) return;
  const row = document.createElement('p');
  row.className = 'review-feedback-field';
  const strong = document.createElement('strong');
  strong.textContent = label + ': ';
  const content = document.createElement('span');
  content.textContent = Array.isArray(value) ? value.join(', ') : String(value);
  row.append(strong, content);
  container.append(row);
}

function renderReviewCoverage() {
  const matrix = document.querySelector('#reviewCoverageMatrix');
  const summary = document.querySelector('#reviewCoverageSummary');
  matrix.replaceChildren();
  const coverage = Array.isArray(reviewerFeedback?.reviewCoverage) ? reviewerFeedback.reviewCoverage : [];
  const verificationEntries = Array.isArray(reviewVerification?.coverageVerification) ? reviewVerification.coverageVerification : [];
  const rejected = verificationEntries.filter(item => item?.verdict === 'rejected').length;
  const blocked = coverage.filter(item => item?.status === 'blocked').length;
  const verificationState = reviewVerificationStale ? 'stale verifier artifact ignored' : (reviewVerification?.verificationStatus || 'awaiting verifier');
  summary.textContent = coverage.length
    ? `${coverage.length} dimension(s); ${rejected} rejected by verifier; ${blocked} blocked; ${verificationState}.`
    : `Review coverage matrix is not available; ${verificationState}.`;
  if (!coverage.length) {
    const empty = document.createElement('p');
    empty.className = 'agent-log-empty';
    empty.textContent = 'Reviewer must publish all configured reviewCoverage dimensions.';
    matrix.append(empty);
    return;
  }
  coverage.forEach(entry => {
    const verification = verificationEntries.find(item => item?.dimension === entry?.dimension);
    const card = document.createElement('article');
    card.className = `review-coverage-card status-${String(entry?.status || 'unknown')} verdict-${String(verification?.verdict || 'pending')}`;
    const header = document.createElement('div');
    header.className = 'review-coverage-card-header';
    const dimension = document.createElement('strong');
    dimension.textContent = String(entry?.dimension || 'unknown').replaceAll('-', ' ');
    const badges = document.createElement('span');
    badges.textContent = [entry?.status, verification?.verdict || 'awaiting verifier'].filter(Boolean).join(' · ');
    header.append(dimension, badges);
    card.append(header);
    appendReviewerFeedbackField(card, 'Reviewer evidence', entry?.evidence);
    appendReviewerFeedbackField(card, 'Reviewer notes', entry?.notes);
    appendReviewerFeedbackField(card, 'Verifier evidence', verification?.evidence);
    appendReviewerFeedbackField(card, 'Falsification', verification?.falsificationAttempts);
    appendReviewerFeedbackField(card, 'Verifier notes', verification?.notes);
    matrix.append(card);
  });
}

function renderFindingLifecycle() {
  const list = document.querySelector('#findingLifecycleList');
  const summary = document.querySelector('#findingLifecycleSummary');
  list.replaceChildren();
  const lifecycle = Array.isArray(reviewerFeedback?.findingLifecycle) ? reviewerFeedback.findingLifecycle : [];
  const lifecycleVerifications = Array.isArray(reviewVerification?.lifecycleVerifications) ? reviewVerification.lifecycleVerifications : [];
  const counts = lifecycle.reduce((result, item) => {
    const key = String(item?.status || 'unknown');
    result[key] = (result[key] || 0) + 1;
    return result;
  }, {});
  const verificationState = reviewVerificationStale ? 'stale verifier artifact ignored' : (reviewVerification?.verificationStatus || 'awaiting verifier');
  summary.textContent = lifecycle.length
    ? `${Object.entries(counts).map(([status, count]) => `${status}: ${count}`).join(' · ')} · ${verificationState}`
    : `No finding lifecycle records · ${verificationState}`;
  lifecycle.forEach(entry => {
    const verification = lifecycleVerifications.find(item => String(item?.findingId || '') === String(entry?.findingId || ''));
    const card = document.createElement('article');
    card.className = `finding-lifecycle-card lifecycle-${String(entry?.status || 'unknown')} verdict-${String(verification?.verdict || 'pending')}`;
    const header = document.createElement('div');
    header.className = 'finding-lifecycle-card-header';
    const findingId = document.createElement('strong');
    findingId.textContent = String(entry?.findingId || 'Finding');
    const badges = document.createElement('span');
    badges.textContent = [entry?.status, verification?.verdict || 'awaiting verifier'].filter(Boolean).join(' · ');
    header.append(findingId, badges);
    card.append(header);
    appendReviewerFeedbackField(card, 'First seen', entry?.firstSeenRevision);
    appendReviewerFeedbackField(card, 'Last observed', entry?.lastObservedRevision);
    appendReviewerFeedbackField(card, 'Resolved', entry?.resolvedRevision);
    appendReviewerFeedbackField(card, 'Previous resolution', entry?.previousResolutionRevision);
    appendReviewerFeedbackField(card, 'Lifecycle evidence', entry?.evidence);
    appendReviewerFeedbackField(card, 'Verifier evidence', verification?.evidence);
    appendReviewerFeedbackField(card, 'Verifier notes', verification?.notes);
    list.append(card);
  });
}

async function sendReviewerFeedbackReply(item, targetAgentId, textarea, buttons) {
  if (!selectedTaskId) throw new Error('Select a task first.');
  const reply = textarea.value.trim();
  if (!reply) throw new Error('Enter a reply for this Reviewer item.');
  const comment = [
    '[Reviewer feedback reply]',
    `Reviewer item: ${item.id}`,
    `Item type: ${item.kind}`,
    '',
    reply
  ].join('\n');
  if (comment.length > 4000) throw new Error('Reply plus Reviewer context exceeds 4000 characters.');
  buttons.forEach(button => { button.disabled = true; });
  setReviewerFeedbackStatus(`Sending ${item.id} reply to ${agentLabels[targetAgentId] || targetAgentId}...`, 'working');
  try {
    const saved = await api('/api/tasks/' + encodeURIComponent(selectedTaskId) + '/comments', {
      method: 'POST',
      body: JSON.stringify({ text: comment, targetAgentId, reviewFindingId: item.id })
    });
    textarea.value = '';
    taskStateRevision += 1;
    await loadTaskDetail(selectedTaskId, taskStateRevision);
    renderReviewerFeedback();
    await loadTaskList({ silent: true });
    setReviewerFeedbackStatus(`${item.id} reply queued for ${agentLabels[targetAgentId] || targetAgentId}.`, 'success');
    log(saved);
  } finally {
    buttons.forEach(button => { button.disabled = false; });
    if (item.verificationVerdict === 'rejected' && buttons[1]) buttons[1].disabled = true;
  }
}

function renderReviewerFeedback() {
  const list = document.querySelector('#reviewFeedbackList');
  const summary = document.querySelector('#reviewFeedbackSummary');
  list.replaceChildren();
  renderReviewQuestionThreads();
  renderReviewCoverage();
  renderFindingLifecycle();
  const items = reviewerFeedbackItems(reviewerFeedback);
  const findings = items.filter(item => item.kind !== 'summary');
  const verificationCounts = findings.reduce((result, item) => {
    const key = item.verificationVerdict || 'awaiting';
    result[key] = (result[key] || 0) + 1;
    return result;
  }, {});
  const verificationState = reviewVerificationStale ? 'stale verifier artifact ignored' : (reviewVerification?.verificationStatus || 'awaiting verifier');
  summary.textContent = reviewerFeedback
    ? `${findings.length} item(s); confirmed ${verificationCounts.confirmed || 0}, rejected ${verificationCounts.rejected || 0}, needs human ${verificationCounts['needs-human'] || 0}, awaiting ${verificationCounts.awaiting || 0}; ${verificationState}.`
    : 'Reviewer outcome is not available.';
  if (!items.length) {
    const empty = document.createElement('p');
    empty.className = 'agent-log-empty';
    empty.textContent = 'No Reviewer outcome, finding, suggestion, or held-scope violation was persisted.';
    list.append(empty);
    renderRequirementTraceability();
    renderReviewCoverage();
    renderFindingLifecycle();
    renderInlineReviewerComments();
    return;
  }
  items.forEach(item => {
    const card = document.createElement('article');
    card.className = 'review-feedback-card';
    const header = document.createElement('div');
    header.className = 'review-feedback-card-header';
    const identity = document.createElement('strong');
    identity.textContent = `${item.id} · ${item.kind}`;
    const badges = document.createElement('span');
    badges.textContent = [item.severity, item.category, item.lifecycleStatus, item.verificationVerdict || (item.kind === 'summary' ? '' : 'awaiting verification'), item.decisionStatus].filter(Boolean).join(' · ') || 'recorded';
    header.append(identity, badges);
    card.append(header);
    appendReviewerFeedbackField(card, 'Summary', item.title || item.summary || item.message);
    appendReviewerFeedbackField(card, 'Location', item.location || item.filePath);
    appendReviewerFeedbackField(card, 'Evidence', item.evidence);
    appendReviewerFeedbackField(card, 'Impact', item.impact);
    appendReviewerFeedbackField(card, 'Suggested correction', item.correctionDirection || item.recommendation || item.suggestion);
    appendReviewerFeedbackField(card, 'Verifier', item.verificationNotes);
    const replies = reviewerFeedbackReplies(item.id);
    if (replies.length) {
      const thread = document.createElement('div');
      thread.className = 'review-feedback-thread';
      replies.forEach(reply => {
        const entry = document.createElement('p');
        const target = agentLabels[reply.targetAgentId] || reply.targetAgentId || 'workflow';
        entry.textContent = `${formatDate(reply.timestampUtc)} → ${target}: ${reply.summary}`;
        thread.append(entry);
      });
      card.append(thread);
    }
    const textarea = document.createElement('textarea');
    textarea.rows = 2;
    textarea.maxLength = 4000;
    textarea.placeholder = `Reply to ${item.id}...`;
    textarea.setAttribute('aria-label', `Reply to Reviewer item ${item.id}`);
    const actions = document.createElement('div');
    actions.className = 'actions review-feedback-actions';
    const reviewerButton = document.createElement('button');
    reviewerButton.type = 'button';
    reviewerButton.className = 'button secondary compact-button';
    reviewerButton.textContent = 'Send to Reviewer';
    const developerButton = document.createElement('button');
    developerButton.type = 'button';
    developerButton.className = 'button primary compact-button';
    developerButton.textContent = 'Send to Developer';
    if (item.verificationVerdict === 'rejected') {
      developerButton.disabled = true;
      developerButton.title = 'Review Verifier rejected this candidate finding.';
    }
    const buttons = [reviewerButton, developerButton];
    reviewerButton.addEventListener('click', async () => {
      try { await sendReviewerFeedbackReply(item, 'reviewer', textarea, buttons); }
      catch (error) { setReviewerFeedbackStatus(error.message, 'error'); log('Error: ' + error.message); }
    });
    developerButton.addEventListener('click', async () => {
      try { await sendReviewerFeedbackReply(item, 'developer', textarea, buttons); }
      catch (error) { setReviewerFeedbackStatus(error.message, 'error'); log('Error: ' + error.message); }
    });
    actions.append(reviewerButton, developerButton);
    card.append(textarea, actions);
    list.append(card);
  });
  renderRequirementTraceability();
  renderInlineReviewerComments();
}

async function loadReviewerFeedback() {
  if (!selectedTaskId || reviewerFeedbackRequestInFlight) return;
  const taskId = selectedTaskId;
  reviewerFeedbackRequestInFlight = true;
  document.querySelector('#reviewFeedbackSummary').textContent = 'Loading Reviewer outcome...';
  try {
    const artifactUrl = name => '/api/tasks/' + encodeURIComponent(taskId) + '/artifacts/' + encodeURIComponent(name);
    const [result, verificationResult, decisionsResult, debtResult] = await Promise.all([
      api(artifactUrl('review-result.json')),
      api(artifactUrl('review-verification.json')).catch(() => null),
      api(artifactUrl('review-decisions.json')).catch(() => null),
      api(artifactUrl('tech-debt-items.json')).catch(() => null)
    ]);
    if (selectedTaskId !== taskId) return;
    reviewerFeedback = JSON.parse(result.artifact.content);
    reviewArtifactSha256 = String(result.artifact.sha256 || '').toLowerCase();
    const verificationCandidate = verificationResult ? JSON.parse(verificationResult.artifact.content) : null;
    reviewVerificationStale = Boolean(verificationCandidate) && (
      !reviewArtifactSha256
      || String(verificationCandidate.reviewArtifactSha256 || '').toLowerCase() !== reviewArtifactSha256
      || String(verificationCandidate.reviewedRevision || '') !== String(reviewerFeedback.reviewedRevision || '')
    );
    reviewVerification = reviewVerificationStale ? null : verificationCandidate;
    reviewerDecisions = decisionsResult ? (JSON.parse(decisionsResult.artifact.content).decisions || []) : [];
    reviewerTechDebtItems = debtResult ? (JSON.parse(debtResult.artifact.content).items || []) : [];
    renderReviewerFeedback();
  } catch (error) {
    reviewerFeedback = null;
    reviewVerification = null;
    reviewArtifactSha256 = '';
    reviewVerificationStale = false;
    reviewerDecisions = [];
    reviewerTechDebtItems = [];
    renderReviewerFeedback();
    setReviewerFeedbackStatus('Reviewer outcome unavailable: ' + error.message, 'error');
  } finally {
    reviewerFeedbackRequestInFlight = false;
  }
}

function diffRepositories() {
  return Array.isArray(diffProperty(reviewDiffIndex, 'Repositories', 'repositories'))
    ? diffProperty(reviewDiffIndex, 'Repositories', 'repositories')
    : [];
}

function findDiffFile(repositoryId, filePath) {
  const repository = diffRepositories().find(item => item.id === repositoryId);
  const files = Array.isArray(repository?.files) ? repository.files : [];
  const file = files.find(item => item.path === filePath);
  return { repository, file };
}

function renderReviewDiffIndex() {
  const repositories = diffRepositories();
  const container = document.querySelector('#reviewDiffFiles');
  container.replaceChildren();
  let totalFiles = 0;
  repositories.forEach(repository => {
    const files = Array.isArray(repository.files) ? repository.files : [];
    totalFiles += files.length;
    const heading = document.createElement('div');
    heading.className = 'diff-repository';
    heading.textContent = repository.repository + ' - ' + repository.branch;
    container.append(heading);
    if (!files.length) {
      const empty = document.createElement('p');
      empty.className = 'agent-log-empty';
      empty.textContent = 'No changes.';
      container.append(empty);
      return;
    }
    files.forEach(file => {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'diff-file';
      button.classList.toggle('selected', repository.id === selectedDiffRepositoryId && file.path === selectedDiffFilePath);
      const status = document.createElement('span');
      status.className = 'diff-file-status';
      status.textContent = String(file.status || '?').slice(0, 1);
      const path = document.createElement('span');
      path.className = 'diff-file-path';
      path.textContent = file.oldPath ? file.oldPath + ' → ' + file.path : file.path;
      const stats = document.createElement('span');
      stats.className = 'diff-file-stats';
      const added = document.createElement('span');
      added.className = 'added';
      added.textContent = file.additions == null ? '+?' : '+' + file.additions;
      const deleted = document.createElement('span');
      deleted.className = 'deleted';
      deleted.textContent = '-' + (file.deletions || 0);
      stats.append(added, deleted);
      button.append(status, path, stats);
      button.addEventListener('click', () => loadReviewDiffFile(repository.id, file.path));
      container.append(button);
    });
  });
  const scopeLabel = reviewDiffScope === 'reviewed-commit' ? 'latest reviewed commit' : 'all task changes';
  document.querySelector('#reviewDiffMeta').textContent = totalFiles
    ? totalFiles + ' changed file(s) across ' + repositories.length + ' task repository/repositories for ' + scopeLabel + '. Select a line to attach exact context.'
    : 'No local or branch changes were found for the repositories assigned to this task.';
}

function parseUnifiedDiff(patch) {
  let oldLine = null;
  let newLine = null;
  return String(patch || '').split(/\r?\n/).map(text => {
    const hunk = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(text);
    if (hunk) {
      oldLine = Number(hunk[1]);
      newLine = Number(hunk[2]);
      return { text, kind: 'hunk', oldLine: null, newLine: null, selectable: false };
    }
    if (text.startsWith('+') && !text.startsWith('+++')) {
      const line = { text, kind: 'added', oldLine: null, newLine, selectable: true };
      newLine += 1;
      return line;
    }
    if (text.startsWith('-') && !text.startsWith('---')) {
      const line = { text, kind: 'deleted', oldLine, newLine: null, selectable: true };
      oldLine += 1;
      return line;
    }
    if (text.startsWith(' ') && oldLine != null && newLine != null) {
      const line = { text, kind: 'context', oldLine, newLine, selectable: true };
      oldLine += 1;
      newLine += 1;
      return line;
    }
    return { text, kind: 'meta', oldLine: null, newLine: null, selectable: false };
  });
}

function resetReviewDiffCommentEditor() {
  const panel = document.querySelector('#reviewDiffCommentPanel');
  const dock = document.querySelector('#reviewDiffCommentDock');
  if (panel && dock) dock.append(panel);
  if (panel) panel.classList.add('hidden');
  document.querySelectorAll('.diff-line.selected').forEach(item => {
    item.classList.remove('selected');
    item.setAttribute('aria-expanded', 'false');
  });
  selectedDiffLine = null;
  const selection = document.querySelector('#reviewDiffSelection');
  if (selection) selection.textContent = 'Select a diff line to comment.';
}

function selectReviewDiffLine(line, button) {
  if (!line.selectable) return;
  const isSameSelection = button.classList.contains('selected') &&
    selectedDiffLine?.repositoryId === selectedDiffRepositoryId &&
    selectedDiffLine?.filePath === selectedDiffFilePath &&
    selectedDiffLine?.oldLine === line.oldLine &&
    selectedDiffLine?.newLine === line.newLine;
  resetReviewDiffCommentEditor();
  if (isSameSelection) return;
  button.classList.add('selected');
  button.setAttribute('aria-expanded', 'true');
  selectedDiffLine = {
    repositoryId: selectedDiffRepositoryId,
    filePath: selectedDiffFilePath,
    oldLine: line.oldLine,
    newLine: line.newLine,
    text: line.text
  };
  const numbers = [];
  if (line.oldLine != null) numbers.push('old ' + line.oldLine);
  if (line.newLine != null) numbers.push('new ' + line.newLine);
  document.querySelector('#reviewDiffSelection').textContent =
    selectedDiffRepositoryId + ' / ' + selectedDiffFilePath + ' (' + numbers.join(', ') + '): ' + line.text;
  const panel = document.querySelector('#reviewDiffCommentPanel');
  button.insertAdjacentElement('afterend', panel);
  panel.classList.remove('hidden');
  document.querySelector('#reviewDiffComment').focus({ preventScroll: true });
}

function renderReviewDiffPatch(result) {
  const file = diffProperty(result, 'File', 'file') || {};
  const patch = diffProperty(result, 'Patch', 'patch') || '';
  const repositoryId = diffProperty(result, 'RepositoryId', 'repositoryId');
  const branch = diffProperty(result, 'Branch', 'branch') || '';
  const head = diffProperty(result, 'Head', 'head') || '';
  document.querySelector('#reviewDiffFileName').textContent = repositoryId + ' / ' + (file.path || selectedDiffFilePath);
  document.querySelector('#reviewDiffFileStats').textContent =
    branch + ' @ ' + String(head).slice(0, 10) + ' · +' + (file.additions ?? '?') + ' / -' + (file.deletions || 0) +
    (diffProperty(result, 'Truncated', 'truncated') ? ' · truncated' : '');
  const container = document.querySelector('#reviewDiffLines');
  resetReviewDiffCommentEditor();
  container.replaceChildren();
  const lines = parseUnifiedDiff(patch);
  if (!lines.length || !patch) {
    const empty = document.createElement('p');
    empty.className = 'agent-log-empty';
    empty.textContent = file.binary ? 'Binary file changed; no text diff is available.' : 'No text diff is available.';
    container.append(empty);
    return;
  }
  lines.forEach(line => {
    const row = document.createElement('button');
    row.type = 'button';
    row.className = 'diff-line ' + line.kind;
    row.disabled = !line.selectable;
    row.setAttribute('role', 'listitem');
    row.dataset.selectable = String(line.selectable);
    row.dataset.repositoryId = String(repositoryId || '');
    row.dataset.filePath = String(file.path || selectedDiffFilePath || '');
    if (line.oldLine != null) row.dataset.oldLine = String(line.oldLine);
    if (line.newLine != null) row.dataset.newLine = String(line.newLine);
    if (line.selectable) {
      row.setAttribute('aria-expanded', 'false');
      row.title = 'Click to comment; click the selected line again to close the editor.';
    }
    const oldNumber = document.createElement('span');
    oldNumber.className = 'diff-line-number';
    oldNumber.textContent = line.oldLine == null ? '' : line.oldLine;
    const newNumber = document.createElement('span');
    newNumber.className = 'diff-line-number';
    newNumber.textContent = line.newLine == null ? '' : line.newLine;
    const code = document.createElement('span');
    code.className = 'diff-line-code';
    code.textContent = line.text || ' ';
    row.append(oldNumber, newNumber, code);
    if (line.selectable) row.addEventListener('click', () => selectReviewDiffLine(line, row));
    container.append(row);
  });
  renderInlineReviewerComments();
}

async function loadReviewDiffFile(repositoryId, filePath) {
  if (!selectedTaskId || reviewDiffRequestInFlight) return;
  const requestedScope = reviewDiffScope;
  selectedDiffRepositoryId = repositoryId;
  selectedDiffFilePath = filePath;
  resetReviewDiffCommentEditor();
  renderReviewDiffIndex();
  document.querySelector('#reviewDiffFileName').textContent = repositoryId + ' / ' + filePath;
  document.querySelector('#reviewDiffFileStats').textContent = 'Loading patch...';
  document.querySelector('#reviewDiffLines').replaceChildren();
  reviewDiffRequestInFlight = true;
  try {
    const query = new URLSearchParams({ repositoryId, filePath, scope: requestedScope });
    const result = await api('/api/tasks/' + encodeURIComponent(selectedTaskId) + '/diff?' + query.toString());
    if (requestedScope !== reviewDiffScope || repositoryId !== selectedDiffRepositoryId || filePath !== selectedDiffFilePath) return;
    renderReviewDiffPatch(result.diff);
  } catch (error) {
    document.querySelector('#reviewDiffFileStats').textContent = 'Diff unavailable';
    document.querySelector('#reviewDiffLines').textContent = error.message;
    log('Error: ' + error.message);
  } finally {
    reviewDiffRequestInFlight = false;
    if (reviewDiffReloadPending) {
      reviewDiffReloadPending = false;
      loadReviewDiff();
    }
  }
}

async function loadReviewDiff() {
  if (!selectedTaskId || reviewDiffRequestInFlight) return;
  const taskId = selectedTaskId;
  const requestedScope = reviewDiffScope;
  reviewDiffRequestInFlight = true;
  document.querySelector('#reviewDiffMeta').textContent = requestedScope === 'reviewed-commit' ? 'Loading latest reviewed commit diff...' : 'Loading all task changes...';
  try {
    const query = new URLSearchParams({ scope: requestedScope });
    const result = await api('/api/tasks/' + encodeURIComponent(taskId) + '/diff?' + query.toString());
    if (selectedTaskId !== taskId || requestedScope !== reviewDiffScope) return;
    reviewDiffIndex = result.diff;
    const repositories = diffRepositories();
    const stillAvailable = findDiffFile(selectedDiffRepositoryId, selectedDiffFilePath).file;
    if (!stillAvailable) {
      const firstRepository = repositories.find(item => Array.isArray(item.files) && item.files.length);
      selectedDiffRepositoryId = firstRepository?.id || null;
      selectedDiffFilePath = firstRepository?.files?.[0]?.path || null;
    }
    renderReviewDiffIndex();
    if (selectedDiffRepositoryId && selectedDiffFilePath) {
      reviewDiffRequestInFlight = false;
      await loadReviewDiffFile(selectedDiffRepositoryId, selectedDiffFilePath);
    } else {
      document.querySelector('#reviewDiffFileName').textContent = 'No changed files';
      document.querySelector('#reviewDiffFileStats').textContent = '';
      document.querySelector('#reviewDiffLines').replaceChildren();
    }
  } catch (error) {
    document.querySelector('#reviewDiffMeta').textContent = 'Diff unavailable: ' + error.message;
    log('Error: ' + error.message);
  } finally {
    reviewDiffRequestInFlight = false;
    if (reviewDiffReloadPending) {
      reviewDiffReloadPending = false;
      loadReviewDiff();
    }
  }
}

function openReviewDiff() {
  if (!selectedTaskId) return;
  reviewDiffScope = 'reviewed-commit';
  document.querySelector('#reviewDiffScope').value = reviewDiffScope;
  document.querySelector('#reviewDiffPanel').classList.remove('hidden');
  document.querySelector('#reviewFeedbackTitle').textContent = `Reviewer feedback for ${selectedTaskId}`;
  setReviewDiffCommentStatus('');
  setReviewerFeedbackStatus('');
  loadReviewDiff();
  loadReviewerFeedback();
  document.querySelector('#reviewDiffPanel').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function buildReviewDiffComment() {
  if (!selectedDiffLine) throw new Error('Select a diff line first.');
  const text = document.querySelector('#reviewDiffComment').value.trim();
  if (!text) throw new Error('Enter a diff comment.');
  const context = [
    '[Task diff line comment]',
    'Repository: ' + selectedDiffLine.repositoryId,
    'File: ' + selectedDiffLine.filePath,
    'Old line: ' + (selectedDiffLine.oldLine ?? 'n/a'),
    'New line: ' + (selectedDiffLine.newLine ?? 'n/a'),
    'Diff line: ' + selectedDiffLine.text,
    '',
    text
  ];
  const comment = context.join('\n');
  if (comment.length > 4000) throw new Error('Comment plus diff context exceeds 4000 characters.');
  return comment;
}

async function sendReviewDiffComment({ restart = false } = {}) {
  if (!selectedTaskId) throw new Error('Select a task first.');
  const targetAgentId = document.querySelector('#reviewDiffCommentTarget').value;
  if (!['reviewer', 'developer'].includes(targetAgentId)) throw new Error('Unsupported diff comment target.');
  const requestedKind = document.querySelector('#reviewDiffCommentKind').value;
  const commentKind = targetAgentId === 'reviewer' ? requestedKind : 'instruction';
  const comment = buildReviewDiffComment();
  if (restart && selectedTask?.status === 'running') throw new Error('Stop the running workflow before restarting one agent.');
  const saved = await api('/api/tasks/' + encodeURIComponent(selectedTaskId) + '/comments', {
    method: 'POST',
    body: JSON.stringify({ text: comment, targetAgentId, commentKind })
  });
  document.querySelector('#reviewDiffComment').value = '';
  taskStateRevision += 1;
  let restarted = null;
  if (restart) {
    restarted = await api('/api/tasks/' + encodeURIComponent(selectedTaskId) + '/agents/' + encodeURIComponent(targetAgentId) + '/resume', {
      method: 'POST',
      body: JSON.stringify({ elevated: true, ...taskViewGuard() })
    });
  }
  setReviewDiffCommentStatus(
    restart
      ? (agentLabels[targetAgentId] || targetAgentId) + ' was restarted with the diff comment.'
      : 'Diff comment was queued for ' + (agentLabels[targetAgentId] || targetAgentId) + '.',
    'success'
  );
  setReviewerFeedbackStatus(
    restart
      ? (agentLabels[targetAgentId] || targetAgentId) + ' was restarted with the selected-line comment.'
      : 'Selected-line comment queued for ' + (agentLabels[targetAgentId] || targetAgentId) + '.',
    'success'
  );
  resetReviewDiffCommentEditor();
  log({ comment: saved, restart: restarted });
  await loadTaskDetail(selectedTaskId, taskStateRevision);
  await loadTaskList({ silent: true });
}

function closeAgentLog() {
  selectedAgentId = null;
  const panel = document.querySelector('#agentLogPanel');
  if (panel) panel.classList.add('hidden');
  document.querySelectorAll('.agent-state.selected').forEach(card => card.classList.remove('selected'));
  setAgentActionStatus('');
}

function openAgentLog(agentId) {
  selectedAgentId = agentId;
  document.querySelector('#agentLogPanel').classList.remove('hidden');
  document.querySelectorAll('.agent-state').forEach(card => card.classList.toggle('selected', card.dataset.agentId === agentId));
  document.querySelector('#agentLogTitle').textContent = `${agentLabels[agentId] || agentId} activity`;
  document.querySelector('#agentLogMeta').textContent = 'Loading live activity...';
  document.querySelector('#agentLogEntries').textContent = '';
  document.querySelector('#agentComment').value = agentCommentDrafts.get(agentDraftKey()) || '';
  setAgentActionStatus('Comment is optional when restarting this agent.');
  loadAgentLog();
}

function renderAgentLog(result) {
  const entries = Array.isArray(result.entries) ? result.entries : [];
  const container = document.querySelector('#agentLogEntries');
  const wasNearBottom = container.scrollHeight - container.scrollTop - container.clientHeight < 80;
  container.replaceChildren();
  document.querySelector('#agentLogTitle').textContent = `${agentLabels[result.agentId] || result.agentId} activity`;
  document.querySelector('#agentLogMeta').textContent = `${result.status || 'pending'} - updated ${formatDate(result.generatedAtUtc)} - refreshes every ${agentLogRefreshSeconds} seconds`;
  if (!entries.length) {
    const empty = document.createElement('p');
    empty.className = 'agent-log-empty';
    empty.textContent = 'No activity has been recorded for this agent yet.';
    container.append(empty);
    return;
  }
  entries.forEach(entry => {
    const item = document.createElement('article');
    item.className = `agent-log-entry log-${entry.level || 'info'}`;
    const header = document.createElement('div');
    const source = document.createElement('strong');
    source.textContent = entry.stage || entry.source || 'activity';
    const time = document.createElement('time');
    time.textContent = entry.timestampUtc ? formatDate(entry.timestampUtc) : `stream #${entry.sequence || '?'}`;
    header.append(source, time);
    const summary = document.createElement('p');
    summary.textContent = entry.summary || 'Activity recorded.';
    item.append(header, summary);
    const facts = [
      ['Operation', entry.operation],
      ['Target', entry.target],
      ['Next', entry.nextAction]
    ].filter(([, value]) => value !== null && value !== undefined && String(value).trim());
    if (facts.length) {
      const metadata = document.createElement('dl');
      metadata.className = 'agent-log-metadata';
      facts.forEach(([label, value]) => {
        const term = document.createElement('dt');
        term.textContent = label;
        const description = document.createElement('dd');
        description.textContent = value;
        metadata.append(term, description);
      });
      item.append(metadata);
    }
    if (entry.progressPercent !== null && entry.progressPercent !== undefined && Number.isFinite(Number(entry.progressPercent))) {
      const progress = document.createElement('div');
      progress.className = 'agent-log-progress';
      const label = document.createElement('span');
      const percent = Math.max(0, Math.min(100, Number(entry.progressPercent)));
      label.textContent = `Progress ${percent}%`;
      const track = document.createElement('div');
      const fill = document.createElement('i');
      fill.style.width = `${percent}%`;
      track.append(fill);
      progress.append(label, track);
      item.append(progress);
    }
    if (entry.details) {
      const details = document.createElement('pre');
      details.textContent = entry.details;
      item.append(details);
    }
    if (Array.isArray(entry.evidence) && entry.evidence.length) {
      const evidence = document.createElement('ul');
      evidence.className = 'agent-log-evidence';
      entry.evidence.forEach(value => {
        const line = document.createElement('li');
        line.textContent = value;
        evidence.append(line);
      });
      item.append(evidence);
    }
    container.append(item);
  });
  if (wasNearBottom || container.dataset.initialized !== 'true') container.scrollTop = container.scrollHeight;
  container.dataset.initialized = 'true';
}

async function loadAgentLog({ silent = false } = {}) {
  if (!selectedTaskId || !selectedAgentId || agentLogRequestInFlight) return;
  const taskId = selectedTaskId;
  const agentId = selectedAgentId;
  agentLogRequestInFlight = true;
  try {
    const result = await api(`/api/tasks/${encodeURIComponent(taskId)}/agents/${encodeURIComponent(agentId)}/log`);
    if (selectedTaskId !== taskId || selectedAgentId !== agentId) return;
    renderAgentLog(result);
  } catch (error) {
    if (selectedTaskId === taskId && selectedAgentId === agentId) {
      document.querySelector('#agentLogMeta').textContent = 'Live activity unavailable';
      if (!silent) log(`Error: ${error.message}`);
    }
  } finally {
    agentLogRequestInFlight = false;
  }
}
async function confirmIdleAgentDispatch(taskId, result) {
  if (result?.dispatch?.status !== 'idle-awaiting-approval') return result;
  const agentId = result.dispatch.agentId;
  const label = agentLabels[agentId] || agentId;
  const approved = window.confirm(`${label} is idle. Start it immediately in elevated mode to process all pending comments as one batch?`);
  if (!approved) {
    result.dispatch.status = 'saved-awaiting-manual-start';
    result.dispatch.reason = `Comment saved for ${label}; immediate start was not approved.`;
    return result;
  }
  const restart = await api(`/api/tasks/${encodeURIComponent(taskId)}/agents/${encodeURIComponent(agentId)}/resume`, {
    method: 'POST',
    body: JSON.stringify({ elevated: true, ...taskViewGuard() })
  });
  result.dispatch.status = 'started';
  result.dispatch.reason = `${label} was idle and started immediately for the pending comment batch.`;
  result.dispatch.restart = restart;
  return result;
}

async function sendSelectedAgentComment({ required = true, refresh = true, autoStartIdle = true } = {}) {
  if (!selectedTaskId || !selectedAgentId) throw new Error('Select an agent first.');
  const taskId = selectedTaskId;
  const agentId = selectedAgentId;
  const draftKey = agentDraftKey(taskId, agentId);
  const field = document.querySelector('#agentComment');
  const text = field.value.trim();
  if (!text) {
    if (required) throw new Error('Enter a comment for the selected agent.');
    return null;
  }
  setAgentActionStatus('Sending comment...', 'working');
  let result = await api(`/api/tasks/${encodeURIComponent(taskId)}/comments`, {
    method: 'POST',
    body: JSON.stringify({ text, targetAgentId: agentId })
  });
  if (autoStartIdle) result = await confirmIdleAgentDispatch(taskId, result);
  taskStateRevision += 1;
  agentCommentDrafts.delete(draftKey);
  if (selectedTaskId === taskId && selectedAgentId === agentId) field.value = '';
  if (result?.dispatch?.status === 'started') {
    setAgentActionStatus(`${agentLabels[agentId] || agentId} started immediately. Additional comments will be batched at its next checkpoint.`, 'success');
  } else if (result?.dispatch?.status === 'queued-for-checkpoint') {
    setAgentActionStatus(`Comment queued for ${agentLabels[agentId] || agentId}. The active workflow will consume it at the next checkpoint; no restart is needed.`, 'success');
  } else {
    setAgentActionStatus(result?.dispatch?.reason || result?.message || `Comment saved for ${agentLabels[agentId] || agentId}.`, 'success');
  }
  if (refresh && selectedTaskId === taskId) {
    await loadTaskDetail(taskId, taskStateRevision);
    await loadAgentLog({ silent: true });
  }
  return result;
}

async function loadTaskDetail(taskId, expectedRevision = taskStateRevision) {
  const result = await api(`/api/tasks/${encodeURIComponent(taskId)}`);
  if (expectedRevision !== taskStateRevision) return;
  renderTaskDetail(result.task);
}

async function loadTaskList({ silent = false } = {}) {
  if (taskRefreshInFlight) return;
  const expectedRevision = taskStateRevision;
  taskRefreshInFlight = true;
  try {
    const suffix = taskFilter === 'all' ? '?includeCompleted=true' : '';
    const result = await api(`/api/tasks${suffix}`);
    if (expectedRevision !== taskStateRevision) return;
    schedulerState = result.scheduler || schedulerState;
    const capacity = Number(schedulerState.capacity || 0);
    const active = Number(schedulerState.activeTaskCount || 0);
    const queued = Number(schedulerState.queuedTaskCount || 0);
    document.querySelector('#capacityStatus').textContent = capacity ? `${active} of ${capacity} task slots active · ${queued} queued` : 'Scheduler capacity is unavailable.';
    renderTaskList(Array.isArray(result.tasks) ? result.tasks : []);
    if (selectedTaskId) await loadTaskDetail(selectedTaskId, expectedRevision);
  } catch (error) {
    if (!silent) log(`Error: ${error.message}`);
  } finally {
    taskRefreshInFlight = false;
  }
}

document.querySelectorAll('[data-mode]').forEach(button => {
  button.addEventListener('click', () => {
    mode = button.dataset.mode;
    document.querySelectorAll('[data-mode]').forEach(item => item.classList.toggle('active', item === button));
    document.querySelector('#manualFields').classList.toggle('hidden', mode !== 'manual');
    document.querySelector('#automateFields').classList.toggle('hidden', mode !== 'automate');
  });
});

document.querySelectorAll('[data-task-filter]').forEach(button => {
  button.addEventListener('click', async () => {
    taskFilter = button.dataset.taskFilter;
    document.querySelectorAll('[data-task-filter]').forEach(item => item.classList.toggle('active', item === button));
    await loadTaskList();
  });
});

document.querySelector('#startWorkflow').addEventListener('click', async () => {
  try {
    const payload = payloadBase();
    if (!payload.repositoryIds.length) throw new Error('Select at least one repository.');
    if (mode === 'manual' && !payload.taskSelector) throw new Error('Enter a task ID, URL, or description.');
    const approved = window.confirm('Start this workflow in host-compatible elevated mode? This avoids the OS sandbox process blocked by CrowdStrike while preserving requirement, review, credential, and external-write gates.');
    if (!approved) return;
    payload.elevated = true;
    const result = await api('/api/workflows/start', { method: 'POST', body: JSON.stringify(payload) });
    selectedTaskId = result.taskId;
    log(result);
    window.setTimeout(() => loadTaskList({ silent: true }), 700);
  } catch (error) { log(`Error: ${error.message}`); }
});

document.querySelector('#refreshTaskStatus').addEventListener('click', () => loadTaskList());
document.querySelectorAll('[data-review-tab]').forEach(button => button.addEventListener('click', () => selectReviewTab(button.dataset.reviewTab).catch(error => log('Error: ' + error.message))));
document.querySelector('#refreshExternalReviews').addEventListener('click', () => loadExternalReviews().catch(error => log('Error: ' + error.message)));

document.querySelector('#runHealthCheck').addEventListener('click', async () => {
  try {
    const button = document.querySelector('#runHealthCheck');
    button.disabled = true;
    button.textContent = 'Checking...';
    const result = await api('/api/health-checks/run', { method: 'POST', body: JSON.stringify({ taskId: selectedTaskId || '' }) });
    log(result);
    await loadTaskList({ silent: true });
  } catch (error) {
    log(`Error: ${error.message}`);
  } finally {
    const button = document.querySelector('#runHealthCheck');
    button.disabled = false;
    button.textContent = 'Run health check';
  }
});

document.querySelector('#sendTaskComment').addEventListener('click', async () => {
  const button = document.querySelector('#sendTaskComment');
  try {
    if (!selectedTaskId) throw new Error('Select a task first.');
    const field = document.querySelector('#taskComment');
    const text = field.value.trim();
    if (!text) throw new Error('Enter a workflow comment.');
    const questionTarget = document.querySelector('#taskQuestionTarget');
    const questionId = questionTarget.value;
    button.disabled = true;
    button.textContent = 'Sending...';
    const result = await api(`/api/tasks/${encodeURIComponent(selectedTaskId)}/comments`, { method: 'POST', body: JSON.stringify({ text, questionId }) });
    taskStateRevision += 1;
    field.value = '';
    questionTarget.value = '';
    document.querySelector('#taskInterventionPanel').open = false;
    log(result);
    await loadTaskDetail(selectedTaskId, taskStateRevision);
    await loadTaskList({ silent: true });
  } catch (error) {
    log(`Error: ${error.message}`);
  } finally {
    button.disabled = false;
    button.textContent = 'Send comment';
  }
});

document.querySelector('#sendAgentComment').addEventListener('click', async () => {
  const button = document.querySelector('#sendAgentComment');
  try {
    button.disabled = true;
    button.textContent = 'Sending...';
    log(await sendSelectedAgentComment());
    await loadTaskList({ silent: true });
  } catch (error) {
    setAgentActionStatus(error.message, 'error');
    log(`Error: ${error.message}`);
  } finally {
    button.disabled = false;
    button.textContent = 'Send to agent';
  }
});

document.querySelector('#restartAgentWithComment').addEventListener('click', async () => {
  const button = document.querySelector('#restartAgentWithComment');
  let restartStarted = false;
  try {
    if (!selectedTaskId || !selectedAgentId) throw new Error('Select an agent first.');
    if (selectedTask?.status === 'running') throw new Error('Stop the running workflow before restarting one agent.');
    const taskId = selectedTaskId;
    const agentId = selectedAgentId;
    const label = agentLabels[agentId] || agentId;
    const approved = window.confirm(`Restart only ${label} in elevated mode? A comment will be sent first if you entered one. Completed work from every other agent will be preserved.`);
    if (!approved) return;
    button.disabled = true;
    button.textContent = 'Restarting...';
    setAgentActionStatus(`Restarting ${label}...`, 'working');
    const comment = await sendSelectedAgentComment({ required: false, refresh: false, autoStartIdle: false });
    const result = await api(`/api/tasks/${encodeURIComponent(taskId)}/agents/${encodeURIComponent(agentId)}/resume`, {
      method: 'POST',
      body: JSON.stringify({ elevated: true, ...taskViewGuard() })
    });
    restartStarted = true;
    taskStateRevision += 1;
    setAgentActionStatus(`${label} restart was queued. Live status will update automatically.`, 'success');
    log({ comment, restart: result });
    if (selectedTaskId === taskId) await loadTaskDetail(taskId, taskStateRevision);
    window.setTimeout(() => loadTaskList({ silent: true }), 700);
  } catch (error) {
    setAgentActionStatus(error.message, 'error');
    log(`Error: ${error.message}`);
  } finally {
    button.disabled = restartStarted || selectedTask?.status === 'running';
    button.textContent = 'Restart agent';
  }
});

document.querySelector('#resumeTask').addEventListener('click', async () => {
  try {
    if (!selectedTask) throw new Error('Select a task first.');
    const payload = {
      mode: selectedTask.mode,
      repositoryIds: Array.isArray(selectedTask.repositoryIds) && selectedTask.repositoryIds.length ? selectedTask.repositoryIds : [selectedTask.repositoryId].filter(Boolean),
      repositoryId: selectedTask.repositoryId,
      taskSelector: selectedTask.selector,
      taskId: selectedTask.taskId,
      expectedRevision: selectedTask.revision ?? null,
      runId: selectedTask.executionRunId || '',
      leaseId: selectedTask.workspaceLeaseId || '',
      instruction: 'Resume from the persisted checkpoint. Run only unfinished agents and preserve every completed agent and artifact.'
    };
    const result = await api('/api/workflows/start', { method: 'POST', body: JSON.stringify(payload) });
    log(result);
    window.setTimeout(() => loadTaskList({ silent: true }), 700);
  } catch (error) { log(`Error: ${error.message}`); }
});

document.querySelector('#stopWorkflow').addEventListener('click', async () => {
  const button = document.querySelector('#stopWorkflow');
  try {
    if (!selectedTaskId) throw new Error('Select a task first.');
    if (!window.confirm('Stop this workflow now? Completed results and task history will be preserved for checkpoint resume.')) return;
    button.disabled = true;
    button.textContent = 'Stopping...';
    const stopTarget = selectedTask;
    const result = await api(`/api/tasks/${encodeURIComponent(selectedTaskId)}/workflow/stop`, {
      method: 'POST',
      body: JSON.stringify({ runId: stopTarget?.executionRunId || '', leaseId: stopTarget?.workspaceLeaseId || '', revision: stopTarget?.revision ?? null })
    });
    taskStateRevision += 1;
    log(result);
    await loadTaskDetail(selectedTaskId, taskStateRevision);
    await loadTaskList({ silent: true });
  } catch (error) {
    log(`Error: ${error.message}`);
  } finally {
    button.textContent = 'Stop workflow';
  }
});

document.querySelector('#closeTaskManually').addEventListener('click', async () => {
  const button = document.querySelector('#closeTaskManually');
  const status = document.querySelector('#manualCloseStatus');
  try {
    if (!selectedTaskId) throw new Error('Select a task first.');
    if (selectedTask?.status === 'running') throw new Error('Stop the workflow before closing the task.');
    const field = document.querySelector('#manualCloseReason');
    const reason = field.value.trim();
    if (reason.length < 5) throw new Error('Enter a closure reason of at least 5 characters.');
    if (!window.confirm('Close this task manually and start only Knowledge Keeper for the final knowledge update?')) return;
    button.disabled = true;
    button.textContent = 'Closing...';
    status.dataset.state = 'working';
    status.textContent = 'Saving the reason and starting Knowledge Keeper...';
    const result = await api('/api/tasks/' + encodeURIComponent(selectedTaskId) + '/close', { method: 'POST', body: JSON.stringify({ reason }) });
    field.value = '';
    document.querySelector('#manualClosePanel').open = false;
    status.dataset.state = 'success';
    status.textContent = result.message;
    taskStateRevision += 1;
    log(result);
    await loadTaskDetail(selectedTaskId, taskStateRevision);
    await loadTaskList({ silent: true });
  } catch (error) {
    status.dataset.state = 'error';
    status.textContent = error.message;
    log('Error: ' + error.message);
  } finally {
    button.textContent = 'Close task and update knowledge';
    button.disabled = selectedTask?.status === 'running' || selectedTask?.status === 'completed';
  }
});

document.querySelector('#reopenTask').addEventListener('click', async () => {
  const button = document.querySelector('#reopenTask');
  const status = document.querySelector('#reopenTaskStatus');
  try {
    if (!selectedTaskId || selectedTask?.status !== 'completed') throw new Error('Select a completed task first.');
    const reasonField = document.querySelector('#reopenTaskReason');
    const reason = reasonField.value.trim();
    const resumeFrom = document.querySelector('#reopenFromAgent').value;
    if (reason.length < 5) throw new Error('Enter a reopen reason of at least 5 characters.');
    if (!window.confirm('Reopen this task as a new revision and automatically continue from ' + (agentLabels[resumeFrom] || resumeFrom) + '?')) return;
    button.disabled = true;
    button.textContent = 'Reopening...';
    status.dataset.state = 'working';
    status.textContent = 'Archiving the current revision and starting the selected agent...';
    const result = await api('/api/tasks/' + encodeURIComponent(selectedTaskId) + '/reopen', { method: 'POST', body: JSON.stringify({ reason, resumeFrom, ...taskViewGuard() }) });
    reasonField.value = '';
    document.querySelector('#reopenTaskPanel').open = false;
    status.dataset.state = 'success';
    status.textContent = result.message;
    taskFilter = 'active';
    document.querySelectorAll('[data-task-filter]').forEach(item => item.classList.toggle('active', item.dataset.taskFilter === 'active'));
    taskStateRevision += 1;
    log(result);
    await loadTaskList({ silent: true });
  } catch (error) {
    status.dataset.state = 'error';
    status.textContent = error.message;
    log('Error: ' + error.message);
  } finally {
    button.disabled = false;
    button.textContent = 'Reopen as new revision';
  }
});

document.querySelector('#resumeElevatedWorkflow').addEventListener('click', async () => {
  try {
    if (!selectedTask) throw new Error('Select a task first.');
    const approved = window.confirm('Resume only unfinished agents without the OS sandbox? Completed agents and artifacts remain unchanged. Requirement, review, credential, and external-write gates still apply.');
    if (!approved) return;
    const result = await api(`/api/tasks/${encodeURIComponent(selectedTask.taskId)}/workflow/elevated`, { method: 'POST', body: JSON.stringify(taskViewGuard()) });
    log(result);
    window.setTimeout(() => loadTaskList({ silent: true }), 700);
  } catch (error) { log(`Error: ${error.message}`); }
});

document.querySelector('#loadTasks').addEventListener('click', async () => {
  const inbox = document.querySelector('#taskInbox');
  inbox.className = 'inbox empty';
  inbox.textContent = 'Loading...';
  try {
    const result = await api('/api/tasks/assigned');
    inbox.replaceChildren();
    inbox.className = 'inbox';
    const workItems = Array.isArray(result.workItems) ? result.workItems : [];
    if (!workItems.length) {
      inbox.className = 'inbox empty';
      inbox.textContent = 'There are no active assigned tasks.';
    }
    workItems.forEach(item => {
      const button = document.createElement('button');
      button.className = 'task-item';
      const title = document.createElement('strong');
      title.textContent = `#${item.id} - ${item.title}`;
      const meta = document.createElement('span');
      meta.textContent = `${item.type} - ${item.state}`;
      button.append(title, meta);
      button.addEventListener('click', () => {
        document.querySelector('[data-mode="manual"]').click();
        document.querySelector('#taskSelector').value = item.url;
        document.querySelector('#taskId').value = `task-${item.id}`;
        log(`Selected task #${item.id}`);
      });
      inbox.append(button);
    });
  } catch (error) {
    inbox.className = 'inbox empty';
    inbox.textContent = error.message;
    log(`Error: ${error.message}`);
  }
});

document.querySelector('#saveReviewerNote').addEventListener('click', async () => {
  try {
    const text = document.querySelector('#reviewerNote').value.trim();
    if (!text) throw new Error('Enter a note for the Reviewer agent.');
    const prValue = document.querySelector('#pullRequestId').value.trim();
    const payload = { ...payloadBase(), text, pullRequestId: prValue ? Number(prValue) : 0 };
    if (!payload.repositoryIds.length) throw new Error('Select at least one repository.');
    log(await api('/api/reviewer-notes', { method: 'POST', body: JSON.stringify(payload) }));
    document.querySelector('#reviewerNote').value = '';
  } catch (error) { log(`Error: ${error.message}`); }
});

document.querySelector('#runReview').addEventListener('click', async () => {
  try {
    const payload = payloadBase();
    if (!payload.repositoryIds.length) throw new Error('Select at least one repository.');
    log(await api('/api/reviews/start', { method: 'POST', body: JSON.stringify(payload) }));
  } catch (error) { log(`Error: ${error.message}`); }
});

document.querySelector('#clearActivity').addEventListener('click', () => { activity.textContent = 'Ready.'; });
document.querySelector('#closeArtifactViewer').addEventListener('click', closeArtifactViewer);
document.querySelector('#closeAgentLog').addEventListener('click', closeAgentLog);
document.querySelector('#closeAgentOutcome').addEventListener('click', closeAgentOutcome);
document.querySelector('#openReviewDiff').addEventListener('click', openReviewDiff);
document.querySelector('#closeReviewDiff').addEventListener('click', closeReviewDiff);
document.querySelector('#refreshReviewDiff').addEventListener('click', () => { loadReviewDiff(); loadReviewerFeedback(); });
document.querySelector('#reviewDiffScope').addEventListener('change', event => {
  reviewDiffScope = event.target.value === 'all-task-changes' ? 'all-task-changes' : 'reviewed-commit';
  selectedDiffRepositoryId = null;
  selectedDiffFilePath = null;
  selectedDiffLine = null;
  if (reviewDiffRequestInFlight) reviewDiffReloadPending = true;
  else loadReviewDiff();
});
document.querySelector('#reviewDiffCommentTarget').addEventListener('change', event => {
  const kind = document.querySelector('#reviewDiffCommentKind');
  const reviewerSelected = event.target.value === 'reviewer';
  kind.disabled = !reviewerSelected;
  if (!reviewerSelected) kind.value = 'instruction';
});
document.querySelector('#sendReviewDiffComment').addEventListener('click', async () => {
  const button = document.querySelector('#sendReviewDiffComment');
  try {
    button.disabled = true;
    button.textContent = 'Sending...';
    setReviewDiffCommentStatus('Saving diff comment...', 'working');
    await sendReviewDiffComment();
  } catch (error) {
    setReviewDiffCommentStatus(error.message, 'error');
    log('Error: ' + error.message);
  } finally {
    button.disabled = false;
    button.textContent = 'Send diff comment';
  }
});
document.querySelector('#sendAndRestartReviewTarget').addEventListener('click', async () => {
  const button = document.querySelector('#sendAndRestartReviewTarget');
  try {
    const targetAgentId = document.querySelector('#reviewDiffCommentTarget').value;
    const approved = window.confirm('Send this diff comment and restart only ' + (agentLabels[targetAgentId] || targetAgentId) + ' in elevated mode? Other agents and completed artifacts remain unchanged.');
    if (!approved) return;
    button.disabled = true;
    button.textContent = 'Restarting...';
    setReviewDiffCommentStatus('Saving comment and restarting only the selected target...', 'working');
    await sendReviewDiffComment({ restart: true });
  } catch (error) {
    setReviewDiffCommentStatus(error.message, 'error');
    log('Error: ' + error.message);
  } finally {
    button.disabled = selectedTask?.status === 'running';
    button.textContent = 'Send and restart target';
  }
});
document.querySelector('#agentComment').addEventListener('input', event => {
  const key = agentDraftKey();
  if (!key) return;
  agentCommentDrafts.set(key, event.target.value);
  setAgentActionStatus('Draft is kept while the dashboard refreshes.');
});
document.querySelector('#approveElevatedRecovery').addEventListener('click', async () => {
  try {
    if (!selectedTaskId) throw new Error('Select a task first.');
    const approved = window.confirm('Run one Health Check repair without the OS sandbox? After a validated repair, Health Check will restart only the failed agent once. Product-code changes, other agents, and approval gates remain out of scope.');
    if (!approved) return;
    const result = await api(`/api/tasks/${encodeURIComponent(selectedTaskId)}/health-recovery/elevated`, { method: 'POST', body: '{}' });
    log(result);
    window.setTimeout(() => loadTaskList({ silent: true }), 700);
  } catch (error) { log(`Error: ${error.message}`); }
});

(async () => {
  try {
    const config = await api('/api/config');
    const configuredAgents = Array.isArray(config.agents) ? config.agents : [];
    configuredAgents.forEach(agent => {
      if (!agentLabels[agent.id]) agentLabels[agent.id] = agent.name || agent.id;
      agentRequiredArtifacts[agent.id] = Array.isArray(agent.requiredArtifacts) ? agent.requiredArtifacts : [];
    });
    repositoryOptions.replaceChildren();
    const repositories = Array.isArray(config.repositories) ? config.repositories : [];
    repositories.forEach((item, index) => {
      const option = document.createElement('label');
      option.className = 'multi-select-option';
      const checkbox = document.createElement('input');
      checkbox.type = 'checkbox';
      checkbox.value = item.id;
      checkbox.checked = index === 0;
      checkbox.dataset.label = `${item.repository} - ${item.provider}`;
      checkbox.addEventListener('change', updateRepositorySummary);
      const label = document.createElement('span');
      label.textContent = checkbox.dataset.label;
      option.append(checkbox, label);
      repositoryOptions.append(option);
    });
    updateRepositorySummary();
    document.querySelector(`[data-mode="${config.mode}"]`).click();
    document.querySelector('#connectionStatus').textContent = 'Local - ready';
    document.querySelector('#connectionStatus').classList.add('online');
    await loadTaskList();
    const refreshMilliseconds = Math.max(2, Number(config.taskRefreshSeconds) || 5) * 1000;
    agentLogRefreshSeconds = Math.max(2, Number(config.agentLogRefreshSeconds) || 30);
    window.setInterval(() => loadTaskList({ silent: true }), refreshMilliseconds);
    window.setInterval(() => loadAgentLog({ silent: true }), agentLogRefreshSeconds * 1000);
  } catch (error) {
    document.querySelector('#connectionStatus').textContent = 'Connection error';
    log(`Error: ${error.message}`);
  }
})();
