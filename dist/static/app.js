const $ = (selector) => document.querySelector(selector);
const API_BASE = (window.__AETHERLAKE_API_BASE__ || "").replace(/\/$/, "");

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
  const response = await fetch(`${API_BASE}${path}`, {
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

function showStorageReceipt(storage) {
  if (!storage?.metadata_location) return;
  $("#storageTablePath").textContent = storage.table_location || `s3://${storage.bucket}/${storage.prefix}/`;
  $("#storageMetadataPath").textContent = storage.metadata_location;
  $("#storageReceipt").hidden = false;
}

function setChecklistState() {
  $("#checkPostgres").classList.add("checked");
  $("#checkCatalog").classList.add("checked");
  $("#checkSnowflake").classList.add("pending");
}

async function loadOverview() {
  try {
    const data = await api("/api/overview");
    $("#measurementCount").textContent = Number(data.metrics.measurement_count ?? 0).toLocaleString();
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
    showStorageReceipt(data.storage);
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



/* ---------------------------------------------------------------- semantic model */

/* Fixed-layer layout, deliberately not force-directed: the diagram must look the same every
   time it renders so it can be pointed at on stage. Layer assignment comes from the model, so
   breaking the YAML really does change the picture. */
const GRAPH = { width: 900, height: 480, boxW: 168, boxH: 62, padX: 34, padY: 34 };

function nodeClass(node) {
  if (node.usedFor === "record") return "record";
  if (node.space.startsWith("cdf_")) return "cdm";
  if (node.space.startsWith("dm_sol_")) return "sdm";
  return "view";
}

function layoutModel(data) {
  const nodes = [];
  data.views.forEach((view) => {
    nodes.push({
      id: view.external_id,
      space: view.space,
      label: view.external_id,
      sub: `${view.property_count} properties`,
      version: view.version,
    });
  });
  data.containers
    .filter((container) => container.used_for === "record")
    .forEach((container) => {
      nodes.push({
        id: container.external_id,
        space: container.space,
        label: container.external_id,
        sub: `record · ${container.property_count} properties`,
        usedFor: "record",
      });
    });

  /* Columns read left to right: system types, enterprise, solution. Records sit with the
     enterprise layer they belong to but are drawn dashed, because they are not in the graph. */
  const column = (node) => {
    if (node.space.startsWith("cdf_")) return 0;
    if (node.space.startsWith("dm_sol_")) return 2;
    return 1;
  };
  const columns = [[], [], []];
  nodes.forEach((node) => columns[column(node)].push(node));

  const colWidth = (GRAPH.width - GRAPH.padX * 2 - GRAPH.boxW) / 2;
  columns.forEach((members, index) => {
    const span = GRAPH.height - GRAPH.padY * 2 - GRAPH.boxH;
    members.forEach((node, position) => {
      node.x = GRAPH.padX + index * colWidth;
      node.y = GRAPH.padY + (members.length === 1 ? span / 2 : (span / (members.length - 1)) * position);
    });
  });
  return nodes;
}

function edgePath(from, to) {
  const x1 = from.x + GRAPH.boxW;
  const y1 = from.y + GRAPH.boxH / 2;
  const x2 = to.x;
  const y2 = to.y + GRAPH.boxH / 2;
  if (x2 < x1) {
    /* Same-column or right-to-left edge: loop out of the left face instead of crossing boxes. */
    return `M ${from.x} ${y1} C ${from.x - 46} ${y1}, ${x2 - 46} ${y2}, ${x2} ${y2}`;
  }
  return `M ${x1} ${y1} C ${x1 + 56} ${y1}, ${x2 - 56} ${y2}, ${x2} ${y2}`;
}

function renderModelGraph(data) {
  const nodes = layoutModel(data);
  const byId = new Map(nodes.map((node) => [node.id, node]));

  const edges = data.relations
    .filter((relation) => byId.has(relation.from_view) && byId.has(relation.to_view))
    .filter((relation) => relation.from_view !== relation.to_view)
    .map((relation) => {
      const from = byId.get(relation.from_view);
      const to = byId.get(relation.to_view);
      const reverse = relation.kind !== "direct";
      return `<g class="edge ${reverse ? "reverse" : "forward"}" data-from="${escapeHtml(relation.from_view)}" data-to="${escapeHtml(relation.to_view)}">
        <path d="${edgePath(from, to)}" />
        <text x="${(from.x + GRAPH.boxW + to.x) / 2}" y="${(from.y + to.y) / 2 + GRAPH.boxH / 2 - 8}">${escapeHtml(relation.property)}</text>
      </g>`;
    })
    .join("");

  const boxes = nodes
    .map(
      (node) => `<g class="node ${nodeClass(node)}" data-view="${escapeHtml(node.id)}" tabindex="0" role="button">
        <rect x="${node.x}" y="${node.y}" width="${GRAPH.boxW}" height="${GRAPH.boxH}" rx="8" />
        <text class="node-label" x="${node.x + 14}" y="${node.y + 26}">${escapeHtml(node.label)}</text>
        <text class="node-sub" x="${node.x + 14}" y="${node.y + 44}">${escapeHtml(node.sub)}</text>
      </g>`
    )
    .join("");

  $("#modelGraph").innerHTML = `<svg viewBox="0 0 ${GRAPH.width} ${GRAPH.height}" preserveAspectRatio="xMidYMid meet">${edges}${boxes}</svg>`;

  $("#modelGraph")
    .querySelectorAll(".node")
    .forEach((node) => {
      const show = () => loadViewDetail(node.dataset.view);
      node.addEventListener("click", show);
      node.addEventListener("keydown", (event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          show();
        }
      });
      node.addEventListener("mouseenter", () => dimUnrelated(node.dataset.view));
      node.addEventListener("mouseleave", () => dimUnrelated(null));
    });
}

function dimUnrelated(view) {
  $("#modelGraph")
    .querySelectorAll(".edge")
    .forEach((edge) => {
      const incident = !view || edge.dataset.from === view || edge.dataset.to === view;
      edge.classList.toggle("dim", !incident);
    });
}

async function loadModel() {
  try {
    renderModelGraph(await api("/api/model"));
  } catch (error) {
    $("#modelGraph").innerHTML = `<p class="muted-note">${escapeHtml(error.message)}</p>`;
  }
}

async function loadViewDetail(externalId) {
  try {
    const data = await api(`/api/model/view/${encodeURIComponent(externalId)}`);
    $("#viewDetailTitle").textContent = `${data.view.space}:${data.view.external_id}/${data.view.version}`;
    const implemented = (data.view.implements || [])
      .map((parent) => `<span class="tag">implements ${escapeHtml(parent)}</span>`)
      .join("");
    const rows = data.properties
      .map(
        (property) => `<li class="property ${escapeHtml(property.kind)}">
          <div class="property-head">
            <code>${escapeHtml(property.identifier)}</code>
            <span class="property-type">${escapeHtml(property.target_view ? `→ ${property.target_view}` : property.pg_type || property.kind)}</span>
          </div>
          <p>${escapeHtml(property.description || "")}</p>
          <small>${escapeHtml(property.container ? `${property.container}.${property.container_identifier}` : property.kind.replace(/_/g, " "))}</small>
        </li>`
      )
      .join("");
    $("#viewDetail").innerHTML = `
      <p class="muted-note">${escapeHtml(data.view.description || "")}</p>
      <div class="tag-row">${implemented}<span class="tag">${escapeHtml(data.view.relation)}</span></div>
      <ul class="property-list">${rows}</ul>`;
  } catch (error) {
    $("#viewDetail").innerHTML = `<p class="muted-note">${escapeHtml(error.message)}</p>`;
  }
}


/* ------------------------------------------------------------------ query explorer */

const PRESETS = {
  wells: {
    space: "dm_dom_well_production",
    view: "Asset",
    version: "v1",
    properties: ["name", "wellType", "wellId", "spudDate"],
    filter: { equals: { property: ["assetType"], value: "well" } },
    traverse: [{ property: "interventions", properties: ["name", "status"] }],
    limit: 10,
    explain: true,
  },
  hierarchy: {
    space: "dm_dom_well_production",
    view: "Asset",
    version: "v1",
    properties: ["name", "assetType", "fieldCode"],
    filter: { equals: { property: ["assetType"], value: "field" } },
    traverse: [{ property: "children", properties: ["name", "assetType"] }],
    limit: 10,
    explain: true,
  },
  sdm: {
    space: "dm_sol_production_analytics",
    view: "WellProductionDaily",
    version: "v1",
    properties: ["productionDate", "wellName", "fieldName", "oilBbl", "waterCutPct", "interventionCount"],
    filter: { range: { property: ["waterCutPct"], gte: 20 } },
    limit: 8,
    explain: true,
  },
  /* Field has no `interventions` relation in the model, so this must be refused. */
  undeclared: {
    space: "dm_dom_well_production",
    view: "Asset",
    version: "v1",
    properties: ["name"],
    traverse: [{ property: "purchaseOrders", properties: ["name"] }],
    limit: 5,
    explain: true,
  },
};

function setQueryStatus(text, variant) {
  const status = $("#queryStatus");
  status.textContent = text;
  status.className = `tag ${variant || ""}`.trim();
}

async function runQuery() {
  const button = $("#queryButton");
  let payload;
  try {
    payload = JSON.parse($("#queryInput").value);
  } catch (error) {
    setQueryStatus("invalid JSON", "error");
    toast("That request is not valid JSON.", true);
    return;
  }

  button.disabled = true;
  $("#queryLabel").textContent = "Resolving…";
  try {
    const data = await api("/api/query", { method: "POST", body: JSON.stringify({ request: payload }) });
    $("#generatedSql").textContent = data.explain?.sql || "(no SQL returned)";
    $("#queryResult").textContent = JSON.stringify(data.items, null, 2);
    setQueryStatus(`${data.rowCount} rows · ${data.queryMs} ms`, "ok");
    $("#querySources").innerHTML = (data.explain?.sources || [])
      .map(
        (source) => `<div class="code-item"><span>${escapeHtml(source.view)}</span>
          <em>snapshot ${escapeHtml(String(source.snapshotId ?? "—"))}</em></div>`
      )
      .join("");
  } catch (error) {
    /* A rejection is the guardrail working. Show it as such rather than as a failure. */
    $("#generatedSql").textContent = "No SQL was generated — the model refused the request.";
    $("#queryResult").textContent = error.message;
    $("#querySources").innerHTML = "";
    setQueryStatus("rejected by the model", "error");
    toast(error.message, true);
  } finally {
    button.disabled = false;
    $("#queryLabel").textContent = "Resolve through the semantic layer";
  }
}

/* --------------------------------------------------------------------- SDM build */

async function runSdmBuild() {
  const button = $("#sdmButton");
  button.disabled = true;
  $("#sdmLabel").textContent = "Building…";
  try {
    const build = await api("/api/sdm/build", { method: "POST", body: "{}" });
    const moved = build.snapshot_before !== build.snapshot_after;
    $("#sdmResult").innerHTML = `
      <div class="code-item"><span>rows written</span><em>${escapeHtml(Number(build.rows_written).toLocaleString())}</em></div>
      <div class="code-item"><span>duration</span><em>${escapeHtml(String(build.duration_ms))} ms</em></div>
      <div class="code-item"><span>snapshot</span><em>${escapeHtml(String(build.snapshot_before ?? "—"))} → ${escapeHtml(String(build.snapshot_after ?? "—"))}</em></div>
      <p class="muted-note">${moved ? "Same rows, new Iceberg snapshot: the rebuild is idempotent without being a no-op." : "Snapshot did not advance."}</p>`;
    await Promise.all([loadLineage(), loadOverview()]);
    toast(`SDM rebuilt: ${Number(build.rows_written).toLocaleString()} rows`);
  } catch (error) {
    $("#sdmResult").innerHTML = `<p class="muted-note">${escapeHtml(error.message)}</p>`;
    toast(error.message, true);
  } finally {
    button.disabled = false;
    $("#sdmLabel").textContent = "Run SDM build";
  }
}

async function loadLineage() {
  try {
    const data = await api("/api/lineage?limit=6");
    $("#lineageList").innerHTML =
      data.builds
        .map(
          (build) => `<div class="lineage">
            <div class="lineage-head">
              <span>#${escapeHtml(String(build.build_id))}</span>
              <em>${escapeHtml(Number(build.rows_written).toLocaleString())} rows · ${escapeHtml(String(build.duration_ms))} ms</em>
            </div>
            <small>${escapeHtml((build.source_views || []).join(" · "))}</small>
            <small>snapshot ${escapeHtml(String(build.snapshot_before ?? "—"))} → ${escapeHtml(String(build.snapshot_after ?? "—"))}</small>
          </div>`
        )
        .join("") || '<p class="muted-note">No build has run yet.</p>';
  } catch (error) {
    $("#lineageList").innerHTML = `<p class="muted-note">${escapeHtml(error.message)}</p>`;
  }
}

document.querySelectorAll("[data-preset]").forEach((button) => {
  button.addEventListener("click", () => {
    $("#queryInput").value = JSON.stringify(PRESETS[button.dataset.preset], null, 2);
    setQueryStatus("idle", "");
  });
});

$("#queryButton").addEventListener("click", runQuery);
$("#sdmButton").addEventListener("click", runSdmBuild);
$("#queryInput").value = JSON.stringify(PRESETS.wells, null, 2);

Promise.all([loadOverview(), loadEvents(), loadModel(), loadLineage()]);
window.setInterval(loadOverview, 15000);
