const token = document.querySelector('meta[name="ecosystem-token"]')?.content || '';
const api = createDashboardApi(token);
const projectSelect = document.querySelector('#project');
let loadSequence = 0;
let activeLoadController = null;
const format = value => value === null || value === undefined ? '—' : Number(value).toLocaleString();
const pct = value => value === null || value === undefined ? '—' : `${(Number(value) * 100).toFixed(1)}%`;
const esc = value => String(value ?? '').replace(/[&<>"']/g, char => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[char]));
function card(label, value, note = '') { return `<div class="card"><span>${esc(label)}</span><strong>${esc(typeof value === 'string' ? value : format(value))}</strong><small>${esc(note)}</small></div>`; }
function rows(items, empty, render) { return items?.length ? items.map(render).join('') : `<tr><td colspan="8" class="muted">${esc(empty)}</td></tr>`; }
function render(result) {
  const analytics = result.analytics || {}, summary = analytics.summary || {}, knowledge = analytics.knowledgeUsage || {}, mcp = analytics.mcp || {};
  document.querySelector('#scope').textContent = `${result.projectId || 'All projects'} · generated ${new Date(result.generatedAtUtc).toLocaleString()}`;
  document.querySelector('#generated').textContent = `${format(summary.taskCount)} tasks · ${format(summary.attemptCount)} role attempts`;
  document.querySelector('#summary').innerHTML = [card('Tasks', summary.taskCount, `${format(summary.activeTaskCount)} active · ${format(summary.completedTaskCount)} completed`), card('Reported tokens', summary.totalTokens, `${format(summary.unavailableTokenRecordCount)} unavailable records`), card('Errors', summary.errorCount, `${format(summary.failedAttemptCount)} failed attempts`), card('Knowledge outcomes', summary.knowledgeOutcomeCount, 'persisted Knowledge Keeper results')].join('');
  document.querySelector('#knowledgeSummary').innerHTML = [card('Map reuse', pct(knowledge.mapReuseRate), `${format(knowledge.mapReusedCount)} reused · ${format(knowledge.mapBuiltCount)} built`), card('Scan avoidance', pct(knowledge.scanAvoidanceRate), `${format(knowledge.fullScanCount)} full scans · ${format(knowledge.targetedSearchCount)} targeted searches · ${format(knowledge.scanCoveredAttemptCount)} covered attempts · ${format(knowledge.scanExcludedCommandCount)} without telemetry · ${format(knowledge.scanUnclassifiedCommandCount)} unclassified. Map events / (map events + full scans); heuristic.`), card('Skill selections', knowledge.skillSelectionCount), card('Unique sources', knowledge.sourceCount)].join('');
  document.querySelector('#mcpSummary').innerHTML = [card('MCP tool calls', mcp.callCount, `${format(mcp.succeededCount)} succeeded`), card('Success rate', pct(mcp.successRate), `${format(mcp.failedCount)} failed`), card('Transport failures', mcp.transportFailureCount, `${pct(mcp.transportFailureRate)} of ${format(mcp.transportEventCount)} transport events`), card('P95 latency', mcp.p95LatencyMs, 'milliseconds'), card('Fallbacks', mcp.fallbackCount, `${format(mcp.serverCount)} servers · ${format(mcp.toolCount)} tools`)].join('');
  document.querySelector('#knowledgeBySource').innerHTML = rows(analytics.knowledgeBySource, 'No knowledge access events yet.', item => `<tr><td>${esc(item.sourceKind)} / ${esc(item.sourceId)}</td><td>${format(item.events)}</td><td>${format(item.selected)}</td><td>${format(item.read)}</td><td>${format(item.reused)}</td><td>${format(item.rebuilt)}</td></tr>`);
  document.querySelector('#mcpByTool').innerHTML = rows(analytics.mcpByTool, 'No MCP calls yet.', item => `<tr><td>${esc(item.server)} / ${esc(item.tool)}</td><td>${format(item.calls)}</td><td>${format(item.succeeded)}</td><td>${pct(item.errorRate)}</td><td>${format(item.p95LatencyMs)}</td><td>${format(item.responseBytes)}</td></tr>`);
  const attempts = new Map((analytics.attemptsByAgent || []).map(item => [item.agentId, item]));
  const usage = new Map((analytics.knowledgeByAgent || []).map(item => [item.agentId, item]));
  const agents = new Set([...(analytics.tokensByAgent || []).map(item => item.agentId), ...attempts.keys(), ...usage.keys()]);
  document.querySelector('#agents').innerHTML = rows([...agents].sort(), 'No agent metrics yet.', agentId => { const t=(analytics.tokensByAgent||[]).find(item=>item.agentId===agentId)||{}, a=attempts.get(agentId)||{}, k=usage.get(agentId)||{}; return `<tr><td>${esc(agentId)}</td><td>${format(t.totalTokens)}</td><td>${format(a.attempts)}</td><td>${format(a.failed)}</td><td>${pct(a.errorRate)}</td><td>${format(k.mapReused)}</td></tr>`; });
  document.querySelector('#tokensByDay').innerHTML = rows(analytics.tokensByDay, 'No token usage yet.', item => `<tr><td>${esc(item.date)}</td><td>${format(item.totalTokens)}</td><td>${format(item.inputTokens)}</td><td>${format(item.outputTokens)}</td><td>${format(item.unavailableRecordCount)}</td></tr>`);
  document.querySelector('#errors').innerHTML = analytics.recentErrors?.length ? analytics.recentErrors.map(item => `<div class="error"><strong>${esc(item.agentId)}: ${esc(item.summary)}</strong><small>${esc(item.timestampUtc || 'timestamp unavailable')} · ${esc(item.taskId)}</small></div>`).join('') : '<p class="muted">No recorded errors.</p>';
}
async function load() {
  const sequence = ++loadSequence;
  if (activeLoadController) activeLoadController.abort();
  activeLoadController = new AbortController();
  const selectedProjectId = projectSelect.value;
  const controller = activeLoadController;
  document.querySelector('#scope').textContent = `${selectedProjectId || 'All projects'} · loading...`;
  try {
    const result = await api(`/api/insights${selectedProjectId ? `?projectId=${encodeURIComponent(selectedProjectId)}` : ''}`, { signal: controller.signal });
    if (sequence === loadSequence && selectedProjectId === projectSelect.value) render(result);
  } catch (error) {
    if (error.name !== 'AbortError' && sequence === loadSequence) document.querySelector('#scope').textContent = `Analytics unavailable: ${error.message}`;
  } finally {
    if (sequence === loadSequence) activeLoadController = null;
  }
}
async function init() { const config = await api('/api/config'); projectSelect.innerHTML = '<option value="">All projects</option>' + (config.projects || []).map(item => `<option value="${esc(item.id)}">${esc(item.name)}</option>`).join(''); projectSelect.addEventListener('change', load); document.querySelector('#refresh').addEventListener('click', load); await load(); }
init().catch(error => { document.querySelector('#scope').textContent = `Analytics unavailable: ${error.message}`; });
