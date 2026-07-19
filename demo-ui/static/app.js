const $ = (selector) => document.querySelector(selector);

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>'"]/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "'": "&#39;",
    '"': "&quot;",
  })[character]);
}

function toast(message, error = false) {
  const element = $("#toast");
  element.textContent = message;
  element.classList.toggle("error", error);
  element.classList.add("show");
  window.setTimeout(() => element.classList.remove("show"), 3600);
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || "The lakehouse request failed");
  return data;
}

function compactPath(path) {
  if (!path) return "metadata pending";
  return path.length > 86 ? `${path.slice(0, 42)}…${path.slice(-32)}` : path;
}

function setChecklistState() {
  $("#checkPostgres").classList.add("checked");
  $("#checkCatalog").classList.add("checked");
  $("#checkSnowflake").classList.add("pending");
}

async function loadOverview() {
  try {
    const data = await api("/api/overview");
    $("#eventCount").textContent = data.metrics.event_count;
    $("#historyCount").textContent = data.metrics.history_count;
    $("#outboxCount").textContent = data.metrics.outbox_count;
    $("#queryMs").textContent = data.metrics.query_ms;

    $("#catalogList").innerHTML = data.catalog.map((table) => `
      <div class="code-item">
        <b>${escapeHtml(table.table_name)}</b>
        <code title="${escapeHtml(table.metadata_location)}">${escapeHtml(compactPath(table.metadata_location))}</code>
      </div>
    `).join("") || "<span class='tag'>No catalog entries</span>";

    $("#extensionList").innerHTML = data.extensions.map((extension) => `
      <span class="tag">${escapeHtml(extension.extname)} · ${escapeHtml(extension.extversion)}</span>
    `).join("");

    $("#jobList").innerHTML = data.jobs.map((job) => `
      <div class="job"><b>${escapeHtml(job.jobname)}</b><span>${escapeHtml(job.schedule)} · ${job.active ? "active" : "paused"}</span></div>
    `).join("") || "<div class='job'><b>Historical sync</b><span>No job configured</span></div>";

    $("#liveLabel").textContent = `PostgreSQL ${data.metrics.postgres_version}`;
    setChecklistState();
  } catch (error) {
    toast(error.message, true);
  }
}

async function loadEvents() {
  try {
    const data = await api("/api/events");
    $("#eventList").innerHTML = data.events.map((event) => `
      <div class="event-row">
        <span class="event-dot"></span>
        <span class="event-type" title="${escapeHtml(event.event_type)}">${escapeHtml(event.event_type)}</span>
        <span class="event-payload">${escapeHtml(JSON.stringify(event.payload))}</span>
        <span class="event-time">${new Date(event.event_time).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" })}</span>
      </div>
    `).join("");
  } catch (error) {
    toast(error.message, true);
  }
}

function highlightNewEvent() {
  const firstRow = document.querySelector(".event-row");
  if (!firstRow) return;
  firstRow.classList.add("flash");
  $("#checkSnowflake").classList.add("checked");
  window.setTimeout(() => firstRow.classList.remove("flash"), 2200);
}

$("#eventForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  const button = event.submitter;
  const form = new FormData(event.currentTarget);
  button.disabled = true;
  $("#submitLabel").textContent = "Committing…";

  try {
    const data = await api("/api/events", {
      method: "POST",
      body: JSON.stringify(Object.fromEntries(form)),
    });
    $("#commitResult").textContent = `COMMITTED ${data.event.event_id}`;
    toast(`Event committed: ${data.event.event_id}`);
    await Promise.all([loadEvents(), loadOverview()]);
    highlightNewEvent();
  } catch (error) {
    $("#commitResult").textContent = `ROLLED BACK · ${error.message}`;
    toast(error.message, true);
  } finally {
    button.disabled = false;
    $("#submitLabel").textContent = "Commit Iceberg transaction";
  }
});

$("#syncButton").addEventListener("click", async (event) => {
  event.currentTarget.disabled = true;
  try {
    const data = await api("/api/sync", { method: "POST", body: "{}" });
    toast(data.message);
    await loadOverview();
  } catch (error) {
    toast(error.message, true);
  } finally {
    event.currentTarget.disabled = false;
  }
});

$("#refreshButton").addEventListener("click", () => Promise.all([loadEvents(), loadOverview()]));

document.querySelectorAll("[data-scroll]").forEach((button) => {
  button.addEventListener("click", () => {
    document.getElementById(button.dataset.scroll).scrollIntoView({ behavior: "smooth" });
  });
});

Promise.all([loadOverview(), loadEvents()]);
window.setInterval(loadOverview, 15000);
