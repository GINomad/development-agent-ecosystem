const token = document.documentElement.dataset.sessionToken;
const activity = document.querySelector('#activity');
const repositoryOptions = document.querySelector('#repositoryOptions');
const repositorySummary = document.querySelector('#repositorySummary');
const agentLabels = {
  knowledge_keeper: 'Knowledge Keeper',
  requirements_analyst: 'Requirements Analyst',
  developer: 'Developer',
  reviewer: 'Reviewer',
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
    meta.textContent = `${item.currentStage || 'no stage'} - ${formatDate(item.updatedAtUtc)}`;
    button.append(heading, selector, meta);
    button.addEventListener('click', async () => {
      if (selectedTaskId !== item.taskId) {
        closeAgentLog();
        closeAgentOutcome();
      }
      selectedTaskId = item.taskId;
      await loadTaskList({ silent: true });
    });
    list.append(button);
  });
}

function renderEmptyTaskDetail() {
  selectedTask = null;
  closeArtifactViewer();
  closeAgentLog();
  closeAgentOutcome();
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
  document.querySelector('#selectedTaskMeta').textContent = `${taskRepositoryIds.join(', ') || 'repositories not recorded'} - stage: ${task.currentStage || 'not reported'} - updated ${formatDate(task.updatedAtUtc)}`;
  document.querySelector('#selectedTaskMessage').textContent = task.lastMessage || 'No status message has been recorded.';

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
    time.textContent = formatDate(state.updatedAtUtc);
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
  document.querySelectorAll('.agent-state.outcome-selected').forEach(card => card.classList.remove('outcome-selected'));
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
    content.textContent = artifact.content || '(empty outcome artifact)';
    document.querySelectorAll('.agent-outcome-artifact').forEach(button => button.classList.toggle('selected', button.dataset.name === name));
  } catch (error) {
    if (selectedTaskId === taskId && selectedOutcomeAgentId === agentId) {
      document.querySelector('#agentOutcomeArtifactMeta').textContent = 'Outcome artifact unavailable';
      content.textContent = error.message;
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
  document.querySelector('#agentOutcomeMeta').textContent = `${state.status || 'pending'} - updated ${formatDate(state.updatedAtUtc)}`;
  document.querySelector('#agentOutcomeSummary').textContent = state.message || 'No persisted outcome summary is available.';
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
    document.querySelector('#agentOutcomeContent').textContent = '';
  }
}

function openAgentOutcome(agentId) {
  selectedOutcomeAgentId = agentId;
  selectedOutcomeArtifactName = null;
  renderAgentOutcome();
  document.querySelector('#agentOutcomePanel').scrollIntoView({ behavior: 'smooth', block: 'nearest' });
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
    if (entry.details) {
      const details = document.createElement('pre');
      details.textContent = entry.details;
      item.append(details);
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
async function sendSelectedAgentComment({ required = true, refresh = true } = {}) {
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
  const result = await api(`/api/tasks/${encodeURIComponent(taskId)}/comments`, {
    method: 'POST',
    body: JSON.stringify({ text, targetAgentId: agentId })
  });
  taskStateRevision += 1;
  agentCommentDrafts.delete(draftKey);
  if (selectedTaskId === taskId && selectedAgentId === agentId) field.value = '';
  setAgentActionStatus(`Comment queued for ${agentLabels[agentId] || agentId}. A running agent will read it after the current work block; no restart is needed.`, 'success');
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
    const result = await api('/api/workflows/start', { method: 'POST', body: JSON.stringify(payload) });
    selectedTaskId = result.taskId;
    log(result);
    window.setTimeout(() => loadTaskList({ silent: true }), 700);
  } catch (error) { log(`Error: ${error.message}`); }
});

document.querySelector('#refreshTaskStatus').addEventListener('click', () => loadTaskList());

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
    const comment = await sendSelectedAgentComment({ required: false, refresh: false });
    const result = await api(`/api/tasks/${encodeURIComponent(taskId)}/agents/${encodeURIComponent(agentId)}/resume`, {
      method: 'POST',
      body: JSON.stringify({ elevated: true })
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
    const result = await api(`/api/tasks/${encodeURIComponent(selectedTaskId)}/workflow/stop`, { method: 'POST', body: '{}' });
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

document.querySelector('#resumeElevatedWorkflow').addEventListener('click', async () => {
  try {
    if (!selectedTask) throw new Error('Select a task first.');
    const approved = window.confirm('Resume only unfinished agents without the OS sandbox? Completed agents and artifacts remain unchanged. Requirement, review, credential, and external-write gates still apply.');
    if (!approved) return;
    const result = await api(`/api/tasks/${encodeURIComponent(selectedTask.taskId)}/workflow/elevated`, { method: 'POST', body: '{}' });
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
document.querySelector('#agentComment').addEventListener('input', event => {
  const key = agentDraftKey();
  if (!key) return;
  agentCommentDrafts.set(key, event.target.value);
  setAgentActionStatus('Draft is kept while the dashboard refreshes.');
});
document.querySelector('#approveElevatedRecovery').addEventListener('click', async () => {
  try {
    if (!selectedTaskId) throw new Error('Select a task first.');
    const approved = window.confirm('Run one Health Check repair without the OS sandbox? The coordinator is instructed to modify only the clean ecosystem repository, but Windows will not enforce that path boundary for this attempt.');
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
