const token = document.documentElement.dataset.sessionToken;
const activity = document.querySelector("#activity");
const repository = document.querySelector("#repository");
let mode = "manual";

function log(value) {
  const text = typeof value === "string" ? value : JSON.stringify(value, null, 2);
  activity.textContent = `[${new Date().toLocaleTimeString()}] ${text}\n\n${activity.textContent}`;
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      "X-Ecosystem-Token": token,
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
    taskSelector: document.querySelector("#taskSelector").value.trim(),
    taskId: document.querySelector("#taskId").value.trim(),
    instruction: document.querySelector("#instruction").value.trim()
  };
}

document.querySelectorAll("[data-mode]").forEach(button => {
  button.addEventListener("click", () => {
    mode = button.dataset.mode;
    document.querySelectorAll("[data-mode]").forEach(item => item.classList.toggle("active", item === button));
    document.querySelector("#manualFields").classList.toggle("hidden", mode !== "manual");
    document.querySelector("#automateFields").classList.toggle("hidden", mode !== "automate");
  });
});

document.querySelector("#startWorkflow").addEventListener("click", async () => {
  try {
    const payload = payloadBase();
    if (mode === "manual" && !payload.taskSelector) throw new Error("Enter a task ID, URL, or description.");
    log(await api("/api/workflows/start", { method: "POST", body: JSON.stringify(payload) }));
  } catch (error) { log(`Error: ${error.message}`); }
});

document.querySelector("#loadTasks").addEventListener("click", async () => {
  const inbox = document.querySelector("#taskInbox");
  inbox.className = "inbox empty";
  inbox.textContent = "Loading...";
  try {
    const result = await api("/api/tasks/assigned");
    inbox.replaceChildren();
    inbox.className = "inbox";
    if (!result.workItems.length) {
      inbox.className = "inbox empty";
      inbox.textContent = "There are no active assigned tasks.";
    }
    result.workItems.forEach(item => {
      const button = document.createElement("button");
      button.className = "task-item";
      const title = document.createElement("strong");
      title.textContent = `#${item.id} - ${item.title}`;
      const meta = document.createElement("span");
      meta.textContent = `${item.type} - ${item.state}`;
      button.append(title, meta);
      button.addEventListener("click", () => {
        document.querySelector('[data-mode="manual"]').click();
        document.querySelector("#taskSelector").value = item.url;
        document.querySelector("#taskId").value = `task-${item.id}`;
        log(`Selected task #${item.id}`);
      });
      inbox.append(button);
    });
  } catch (error) {
    inbox.className = "inbox empty";
    inbox.textContent = error.message;
    log(`Error: ${error.message}`);
  }
});

document.querySelector("#saveReviewerNote").addEventListener("click", async () => {
  try {
    const text = document.querySelector("#reviewerNote").value.trim();
    if (!text) throw new Error("Enter a note for the Reviewer agent.");
    const prValue = document.querySelector("#pullRequestId").value.trim();
    const payload = { ...payloadBase(), text, pullRequestId: prValue ? Number(prValue) : 0 };
    log(await api("/api/reviewer-notes", { method: "POST", body: JSON.stringify(payload) }));
    document.querySelector("#reviewerNote").value = "";
  } catch (error) { log(`Error: ${error.message}`); }
});

document.querySelector("#runReview").addEventListener("click", async () => {
  try {
    log(await api("/api/reviews/start", { method: "POST", body: JSON.stringify(payloadBase()) }));
  } catch (error) { log(`Error: ${error.message}`); }
});

document.querySelector("#clearActivity").addEventListener("click", () => { activity.textContent = "Ready."; });

(async () => {
  try {
    const config = await api("/api/config");
    repository.replaceChildren();
    config.repositories.forEach(item => {
      const option = document.createElement("option");
      option.value = item.id;
      option.textContent = `${item.repository} - ${item.provider}`;
      repository.append(option);
    });
    document.querySelector(`[data-mode="${config.mode}"]`).click();
    document.querySelector("#connectionStatus").textContent = "Local - ready";
    document.querySelector("#connectionStatus").classList.add("online");
  } catch (error) {
    document.querySelector("#connectionStatus").textContent = "Connection error";
    log(`Error: ${error.message}`);
  }
})();
