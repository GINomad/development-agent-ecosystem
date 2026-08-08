const token = document.documentElement.dataset.sessionToken;
const activity = document.querySelector('#activity');
const repository = document.querySelector('#repository');
const agentLabels = {
  knowledge_keeper: 'Knowledge Keeper',
  requirements_analyst: 'Requirements Analyst',
  developer: 'Developer',
  reviewer: 'Reviewer',
  pipeline_monitor: 'Pipeline Monitor',
  health_check: 'Health Check'
};
let mode = 'manual';
let taskFilter = 'active';
let selectedTaskId = null;
let selectedTask = null;
let selectedArtifactName = null;
let taskRefreshInFlight = false;

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

function payloadBase() {
  return {
    mode,
    repositoryId: repository.value,
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

function renderTaskList(tasks) {
  tasks = Array.isArray(tasks) ? tasks : [];
  const list = document.querySelector('#taskList');
  list.replaceChildren();
  if (!tasks.length) {
    list.className = 'task-list empty';
    list.textContent = taskFilter === 'active' ? 'No active tasks.' : 'No persisted tasks.';
    selectedTaskId = null;
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
      selectedTaskId = item.taskId;
      await loadTaskList({ silent: true });
    });
    list.append(button);
  });
}

function renderEmptyTaskDetail() {
  selectedTask = null;
  closeArtifactViewer();
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
  document.querySelector('#selectedTaskMeta').textContent = `${task.repositoryId || 'repository not recorded'} - stage: ${task.currentStage || 'not reported'} - updated ${formatDate(task.updatedAtUtc)}`;
  document.querySelector('#selectedTaskMessage').textContent = task.lastMessage || 'No status message has been recorded.';

  const agentGrid = document.querySelector('#agentStatusGrid');
  agentGrid.replaceChildren();
  Object.entries(agentLabels).forEach(([id, label]) => {
    const state = task.agentStatuses?.[id] || { status: 'pending', message: '', updatedAtUtc: null };
    const card = document.createElement('div');
    card.className = `agent-state ${statusClass(state.status)}`;
    const top = document.createElement('div');
    top.className = 'agent-state-top';
    const name = document.createElement('strong');
    name.textContent = label;
    const badge = document.createElement('span');
    badge.textContent = state.status;
    top.append(name, badge);
    const message = document.createElement('p');
    message.textContent = state.message || 'No activity recorded.';
    const time = document.createElement('small');
    time.textContent = formatDate(state.updatedAtUtc);
    card.append(top, message, time);
    agentGrid.append(card);
  });

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

async function loadTaskDetail(taskId) {
  const result = await api(`/api/tasks/${encodeURIComponent(taskId)}`);
  renderTaskDetail(result.task);
}

async function loadTaskList({ silent = false } = {}) {
  if (taskRefreshInFlight) return;
  taskRefreshInFlight = true;
  try {
    const suffix = taskFilter === 'all' ? '?includeCompleted=true' : '';
    const result = await api(`/api/tasks${suffix}`);
    renderTaskList(Array.isArray(result.tasks) ? result.tasks : []);
    if (selectedTaskId) await loadTaskDetail(selectedTaskId);
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
  try {
    if (!selectedTaskId) throw new Error('Select a task first.');
    const field = document.querySelector('#taskComment');
    const text = field.value.trim();
    if (!text) throw new Error('Enter a workflow comment.');
    const result = await api(`/api/tasks/${encodeURIComponent(selectedTaskId)}/comments`, { method: 'POST', body: JSON.stringify({ text }) });
    field.value = '';
    log(result);
    await loadTaskList({ silent: true });
  } catch (error) { log(`Error: ${error.message}`); }
});

document.querySelector('#resumeTask').addEventListener('click', async () => {
  try {
    if (!selectedTask) throw new Error('Select a task first.');
    const payload = {
      mode: selectedTask.mode,
      repositoryId: selectedTask.repositoryId,
      taskSelector: selectedTask.selector,
      taskId: selectedTask.taskId,
      instruction: 'Resume the persisted task. Read and process all unacknowledged user comments before the next handoff.'
    };
    const result = await api('/api/workflows/start', { method: 'POST', body: JSON.stringify(payload) });
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
    log(await api('/api/reviewer-notes', { method: 'POST', body: JSON.stringify(payload) }));
    document.querySelector('#reviewerNote').value = '';
  } catch (error) { log(`Error: ${error.message}`); }
});

document.querySelector('#runReview').addEventListener('click', async () => {
  try {
    log(await api('/api/reviews/start', { method: 'POST', body: JSON.stringify(payloadBase()) }));
  } catch (error) { log(`Error: ${error.message}`); }
});

document.querySelector('#clearActivity').addEventListener('click', () => { activity.textContent = 'Ready.'; });
document.querySelector('#closeArtifactViewer').addEventListener('click', closeArtifactViewer);
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
    repository.replaceChildren();
    const repositories = Array.isArray(config.repositories) ? config.repositories : [];
    repositories.forEach(item => {
      const option = document.createElement('option');
      option.value = item.id;
      option.textContent = `${item.repository} - ${item.provider}`;
      repository.append(option);
    });
    document.querySelector(`[data-mode="${config.mode}"]`).click();
    document.querySelector('#connectionStatus').textContent = 'Local - ready';
    document.querySelector('#connectionStatus').classList.add('online');
    await loadTaskList();
    const refreshMilliseconds = Math.max(2, Number(config.taskRefreshSeconds) || 5) * 1000;
    window.setInterval(() => loadTaskList({ silent: true }), refreshMilliseconds);
  } catch (error) {
    document.querySelector('#connectionStatus').textContent = 'Connection error';
    log(`Error: ${error.message}`);
  }
})();
