const token = document.documentElement.dataset.sessionToken;
const activity = document.querySelector('#activity');
const repository = document.querySelector('#repository');
const agentLabels = {
  knowledge_keeper: 'Knowledge Keeper',
  requirements_analyst: 'Requirements Analyst',
  developer: 'Developer',
  reviewer: 'Reviewer',
  pipeline_monitor: 'Pipeline Monitor'
};
let mode = 'manual';
let taskFilter = 'active';
let selectedTaskId = null;
let selectedTask = null;
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

  const timeline = document.querySelector('#taskTimeline');
  timeline.replaceChildren();
  if (!task.events.length) timeline.textContent = 'No events recorded.';
  task.events.forEach(event => {
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

  const artifacts = document.querySelector('#taskArtifacts');
  artifacts.replaceChildren();
  if (!task.artifacts.length) artifacts.textContent = 'No artifacts produced yet.';
  task.artifacts.forEach(artifact => {
    const item = document.createElement('div');
    item.className = 'artifact-item';
    const name = document.createElement('strong');
    name.textContent = artifact.name;
    const meta = document.createElement('span');
    meta.textContent = `${artifact.length} bytes - ${formatDate(artifact.lastWriteTimeUtc)}`;
    item.append(name, meta);
    artifacts.append(item);
  });

  const resume = document.querySelector('#resumeTask');
  resume.disabled = task.status === 'running';
  resume.textContent = task.status === 'running' ? 'Workflow is running' : 'Resume workflow';
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
    renderTaskList(result.tasks);
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
    if (!result.workItems.length) {
      inbox.className = 'inbox empty';
      inbox.textContent = 'There are no active assigned tasks.';
    }
    result.workItems.forEach(item => {
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

(async () => {
  try {
    const config = await api('/api/config');
    repository.replaceChildren();
    config.repositories.forEach(item => {
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
