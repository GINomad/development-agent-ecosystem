const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../dashboard/app.js'), 'utf8');
const analyticsSource = fs.readFileSync(path.join(__dirname, '../dashboard/analytics.js'), 'utf8');
const apiSource = fs.readFileSync(path.join(__dirname, '../dashboard/api-client.js'), 'utf8');
function extract(name, code = source) {
  const start = code.indexOf(`async function ${name}(`);
  const end = code.indexOf('\n}', start) + 2;
  assert.ok(start >= 0 && end > start);
  return code.slice(start, end);
}
const flush = () => new Promise(resolve => setImmediate(resolve));

async function sessionRecovery() {
  let sessionReads = 0;
  const requests = [];
  const context = vm.createContext({
    token: 'expired', sessionRefresh: null,
    DOMParser: class { parseFromString() { return { documentElement: { dataset: { sessionToken: 'renewed' } } }; } },
    fetch: async (url, options) => {
      if (url === '/') {
        sessionReads++;
        await flush();
        return { ok: true, text: async () => '<html data-session-token="renewed">' };
      }
      requests.push({ url, method: options.method || 'GET', token: options.headers['X-Ecosystem-Token'] });
      const ok = options.headers['X-Ecosystem-Token'] === 'renewed';
      return { ok, status: ok ? 200 : 403, json: async () => ok ? { entries: [1] } : { error: 'Invalid dashboard session token.' } };
    }
  });
  vm.runInContext(apiSource, context);
  context.api = context.createDashboardApi('expired');
  const results = await Promise.all([context.api('/log/a'), context.api('/log/b')]);
  assert.ok(results.every(result => result.entries.length === 1));
  assert.equal(sessionReads, 1, 'Concurrent reads should share session refresh');
  assert.equal(requests.length, 4, 'Each failed read should be retried once');
  await assert.rejects(context.createDashboardApi('expired')('/comments', { method: 'POST' }), /Invalid dashboard session token/);
  assert.equal(sessionReads, 1, 'Writes must not be automatically repeated');
  assert.equal(requests.filter(request => request.method === 'POST').length, 1);
}

async function concurrentAnalyticsAndActivity() {
  const pending = [];
  const analyticsRenders = [];
  const logRenders = [];
  const elements = new Map();
  const element = id => {
    if (!elements.has(id)) elements.set(id, { textContent: '', disabled: false });
    return elements.get(id);
  };
  const context = vm.createContext({
    projectPicker: { value: 'planning-space' }, configuredProjects: [{ id: 'lss', name: 'LSS' }],
    insightsRequestInFlight: false, insightsReloadPending: false,
    selectedTaskId: 'task', selectedAgentId: 'developer',
    agentLogRequestInFlight: false, agentLogController: null, agentLogRequestKey: '',
    AbortController, window: { setTimeout, clearTimeout },
    document: { querySelector: element }, formatDate: value => value,
    log() {}, renderKnowledge() {}, renderAnalytics: result => analyticsRenders.push(result.projectId),
    renderAgentLog: result => logRenders.push(result.agentId),
    api: url => new Promise((resolve, reject) => pending.push({ url, resolve, reject }))
  });
  vm.runInContext(extract('loadInsights') + '\n' + extract('loadAgentLog'), context);
  const oldAnalytics = context.loadInsights();
  context.projectPicker.value = 'lss';
  await context.loadInsights();
  const activity = context.loadAgentLog();
  pending[1].resolve({ agentId: 'developer' });
  await activity;
  assert.deepEqual(logRenders, ['developer'], 'Live activity should render while analytics is pending');
  pending[0].resolve({ analytics: { projectId: 'planning-space' } });
  await oldAnalytics;
  assert.equal(pending.length, 3, 'A project switch must trigger a fresh request');
  assert.deepEqual(analyticsRenders, [], 'Old project data must not render under a new selection');
  assert.match(pending[2].url, /projectId=lss/);
  pending[2].resolve({ analytics: { projectId: 'lss' }, generatedAtUtc: 'now' });
  await flush();
  assert.deepEqual(analyticsRenders, ['lss']);
  assert.match(element('#insightsScope').textContent, /LSS/);
}

async function standaloneProjectRace() {
  const pending = [];
  const renders = [];
  const context = vm.createContext({
    loadSequence: 0, activeLoadController: null, projectSelect: { value: '' },
    AbortController, document: { querySelector: () => ({ textContent: '' }) },
    render: result => renders.push(result.projectId),
    api: (url, options) => new Promise(resolve => pending.push({ url, signal: options.signal, resolve }))
  });
  vm.runInContext(extract('load', analyticsSource), context);
  const all = context.load();
  context.projectSelect.value = 'planning-space';
  const planning = context.load();
  context.projectSelect.value = 'lss';
  const lss = context.load();
  assert.ok(pending[0].signal.aborted && pending[1].signal.aborted);
  pending[2].resolve({ projectId: 'lss' });
  await lss;
  pending[0].resolve({ projectId: null });
  pending[1].resolve({ projectId: 'planning-space' });
  await Promise.all([all, planning]);
  assert.deepEqual(renders, ['lss'], 'Only the last selected project may render');
}

async function agentSwitch() {
  const pending = [];
  const renders = [];
  const meta = { textContent: '' };
  const context = vm.createContext({
    selectedTaskId: 'task', selectedAgentId: 'developer',
    agentLogRequestInFlight: false, agentLogController: null, agentLogRequestKey: '',
    AbortController, window: { setTimeout, clearTimeout },
    document: { querySelector: () => meta },
    log() {}, renderAgentLog: result => renders.push(result.agentId),
    api: (url, options) => new Promise(resolve => pending.push({ url, signal: options.signal, resolve }))
  });
  vm.runInContext(extract('loadAgentLog'), context);
  const first = context.loadAgentLog();
  await context.loadAgentLog();
  assert.equal(pending.length, 1, 'Polling should not duplicate the same in-flight request');
  context.selectedAgentId = 'reviewer';
  const second = context.loadAgentLog();
  assert.equal(pending.length, 2, 'Switching agents must load immediately');
  assert.equal(pending[0].signal.aborted, true);
  pending[0].resolve({ agentId: 'developer' });
  await first;
  assert.equal(context.agentLogRequestInFlight, true, 'An old request must not unlock the new request');
  pending[1].resolve({ agentId: 'reviewer' });
  await second;
  assert.deepEqual(renders, ['reviewer']);
  assert.equal(context.agentLogRequestInFlight, false);
  context.api = async () => { throw new Error('server unavailable'); };
  await context.loadAgentLog({ silent: true });
  assert.match(meta.textContent, /server unavailable/);
  assert.equal(context.agentLogRequestInFlight, false, 'Failure must allow the next refresh');
}

(async () => {
  await sessionRecovery();
  await agentSwitch();
  await concurrentAnalyticsAndActivity();
  await standaloneProjectRace();
  console.log('passed: session refresh, concurrent reads, write non-replay, agent switching, stale response, error recovery, simultaneous analytics/activity, project races');
})().catch(error => { console.error(error); process.exitCode = 1; });
