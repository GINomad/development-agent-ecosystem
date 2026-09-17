const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../dashboard/app.js'), 'utf8');
const start = source.indexOf('async function sendReviewerFeedbackReply(');
const end = source.indexOf('\nfunction renderReviewerFeedback()', start);
assert.ok(start >= 0 && end > start, 'Production review action functions must exist');
function fixture(dispatch, failRequest = false) {
  const requests = [], statuses = [], reloads = [];
  const context = vm.createContext({
    selectedTaskId: 'task-test', taskStateRevision: 4,
    reviewerFeedback: { reviewedRevision: 'commit-123' }, reviewArtifactSha256: 'a'.repeat(64),
    agentLabels: { developer: 'Developer' },
    taskViewGuard: () => ({ expectedRevision: 7, runId: 'run-1', leaseId: 'lease-1' }),
    api: async (url, options) => {
      requests.push({ url, body: JSON.parse(options.body) });
      if (failRequest) throw new Error('Request rejected');
      return { status: 'approved', dispatch };
    },
    loadTaskDetail: async (...args) => reloads.push(args),
    loadTaskList: async () => {}, renderReviewerFeedback: () => {}, log: () => {},
    setReviewerFeedbackStatus: (text, level) => statuses.push({ text, level })
  });
  vm.runInContext(source.slice(start, end), context);
  return { context, requests, statuses, reloads };
}
const item = { id: 'REV-101', kind: 'finding', verificationVerdict: 'confirmed' };
test('approval sends exact review and task identity, refreshes, reports scheduled', async () => {
  const f = fixture({ status: 'scheduled' });
  const textarea = { value: 'Approved correction' }, buttons = [{ disabled: false }];
  await f.context.approveReviewerFinding(item, textarea, buttons);
  assert.deepEqual(f.requests[0], { url: '/api/tasks/task-test/review-decisions', body: {
    findingId: 'REV-101', decision: 'approved', note: 'Approved correction',
    expectedReviewedRevision: 'commit-123', expectedReviewArtifactSha256: 'a'.repeat(64),
    expectedRevision: 7, runId: 'run-1', leaseId: 'lease-1'
  } });
  assert.equal(f.reloads.length, 1);
  assert.equal(f.statuses.at(-1).level, 'success');
  assert.match(f.statuses.at(-1).text, /Developer was scheduled/);
  assert.equal(textarea.value, '');
  assert.equal(buttons[0].disabled, false);
});
for (const status of ['approval-required', 'failed']) {
  test(`approval ${status} refreshes saved decision for retry without false success`, async () => {
    const f = fixture({ status, reason: 'Developer was not started.' });
    await f.context.approveReviewerFinding(item, { value: 'approved' }, []);
    assert.equal(f.reloads.length, 1);
    assert.deepEqual(f.statuses.at(-1), { text: 'Developer was not started.', level: 'error' });
  });
}
test('active workflow approval reports checkpoint rather than another launch', async () => {
  const f = fixture({ status: 'queued-for-checkpoint', reason: 'Active workflow will consume approval.' });
  await f.context.approveReviewerFinding(item, { value: '' }, []);
  assert.equal(f.statuses.at(-1).text, 'Active workflow will consume approval.');
});
test('retry sends resume, refreshes state and reports failure truthfully', async () => {
  const f = fixture({ status: 'failed', reason: 'Retry failed.' });
  await f.context.resumeApprovedReviewerFinding(item, []);
  assert.equal(f.requests[0].body.decision, 'resume');
  assert.equal(f.requests[0].body.expectedReviewArtifactSha256, 'a'.repeat(64));
  assert.equal(f.reloads.length, 1);
  assert.equal(f.statuses.at(-1).level, 'error');
});
test('plain approved text remains a comment and idle is not reported as queued', async () => {
  const f = fixture({ status: 'idle-awaiting-approval', reason: 'Developer is idle.' });
  await f.context.sendReviewerFeedbackReply(item, 'developer', { value: 'approved' }, []);
  assert.equal(f.requests[0].url, '/api/tasks/task-test/comments');
  assert.equal(f.requests[0].body.decision, undefined);
  assert.equal(f.statuses.at(-1).level, 'error');
  assert.match(f.statuses.at(-1).text, /Developer is idle/);
  assert.match(f.statuses.at(-1).text, /did not approve/);
  assert.doesNotMatch(f.statuses.at(-1).text, /reply queued/);
});
test('rejected request releases controls without clearing user note or claiming success', async () => {
  const f = fixture(null, true), textarea = { value: 'Keep my note' }, buttons = [{ disabled: false }];
  await assert.rejects(f.context.approveReviewerFinding(item, textarea, buttons), /Request rejected/);
  assert.equal(textarea.value, 'Keep my note');
  assert.equal(buttons[0].disabled, false);
  assert.ok(!f.statuses.some(status => status.level === 'success'));
});
