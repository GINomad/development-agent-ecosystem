const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');
const source = fs.readFileSync(process.argv[2] || require('node:path').join(__dirname, '../dashboard/app.js'), 'utf8');
function extract(name, async = false) {
  const start = source.indexOf(`${async ? 'async ' : ''}function ${name}(`);
  const end = source.indexOf('\n}', start) + 2;
  assert.ok(start >= 0 && end > start, `Missing ${name}`);
  return source.slice(start, end);
}
function element() {
  return {children: [], textContent: '', replaceChildren() {this.children=[];}, append(...nodes){this.children.push(...nodes);}, addEventListener(){}};
}
function fixture() {
  const list=element();
  const context=vm.createContext({
    projectPicker: {value:'planning-space'}, configuredProjects:[{id:'planning-space',name:'PlanningSpace'},{id:'lss',name:'Strive'}],
    selectedTaskId:null, taskFilter:'active', statusClass:x=>x, formatDate:x=>x,
    closeAgentLog(){}, renderEmptyTaskDetail(){},
    document:{querySelector:()=>list,createElement:element}
  });
  vm.runInContext(extract('renderTaskList'),context);
  return {list,context};
}
const tasks=[
  {taskId:'task-1890164',projectId:'planning-space',projectName:'PlanningSpace',selector:'Excel audit',status:'running'},
  {taskId:'other-project',projectId:'lss',projectName:'Strive',selector:'LSS task',status:'running'},
  {taskId:'genuine-legacy',selector:'Unassigned historical task',status:'held'}
];
test('PlanningSpace card retains its configured display name and excludes LSS work',()=>{
  const f=fixture();f.context.renderTaskList(tasks);
  assert.deepEqual(f.list.children.map(button=>button.children[1].textContent),['[PlanningSpace] Excel audit','[legacy project] Unassigned historical task']);
  assert.equal(f.context.selectedTaskId,'task-1890164');
});
test('switching project removes PlanningSpace and retains genuinely unassigned history',()=>{
  const f=fixture();f.context.renderTaskList(tasks);f.context.projectPicker.value='lss';f.context.renderTaskList(tasks);
  assert.deepEqual(f.list.children.map(button=>button.children[1].textContent),['[Strive] LSS task','[legacy project] Unassigned historical task']);
  assert.equal(f.context.selectedTaskId,'other-project');
});
test('unknown persisted project keeps its identity instead of becoming legacy',()=>{
  const f=fixture();f.context.projectPicker.value='retired';f.context.renderTaskList([{taskId:'old',projectId:'retired',selector:'Historical',status:'held'}]);
  assert.equal(f.list.children[0].children[1].textContent,'[retired] Historical');
});
test('stale list response cannot restore previous-project selection after revision changes',async()=>{
  let resolve;const renders=[];
  const context=vm.createContext({taskRefreshInFlight:false,taskStateRevision:1,taskFilter:'active',selectedTaskId:null,schedulerState:{},
    api:()=>new Promise(r=>{resolve=r;}),document:{querySelector:()=>({textContent:''})},renderTaskList:items=>renders.push(items),loadTaskDetail:async()=>{},log(){}});
  vm.runInContext(extract('loadTaskList',true),context);
  const request=context.loadTaskList();context.taskStateRevision+=1;resolve({tasks});await request;
  assert.equal(renders.length,0);assert.equal(context.taskRefreshInFlight,false);
});

test('project picker change invalidates in-flight views and requests a fresh list',()=>{
  let handler; const calls=[];
  const context=vm.createContext({
    projectPicker:{addEventListener:(name,callback)=>{assert.equal(name,'change');handler=callback;}},
    taskStateRevision:7,selectedTaskId:'previous-project-task',
    renderProjectRepositories:()=>calls.push('repositories'),renderEmptyTaskDetail:()=>calls.push('clear-detail'),
    loadTaskList:async()=>calls.push('tasks'),loadInsights:async()=>calls.push('insights')
  });
  const start=source.indexOf("projectPicker.addEventListener('change', () => {");
  const end=source.indexOf('\n    });',start)+8;
  assert.ok(start>=0 && end>start);
  vm.runInContext(source.slice(start,end),context);handler();
  assert.equal(context.taskStateRevision,8);assert.equal(context.selectedTaskId,null);
  assert.deepEqual(calls,['repositories','clear-detail','tasks','insights']);
});