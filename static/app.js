const roleSelect = document.querySelector("#role-select");
const logList = document.querySelector("#activity-log");
const roleLabels = { admin: "HR / Admin", pharmacist: "Pharmacist", auditor: "Auditor" };
const reportDefinitions = {
  A: { title: "Report A · Expiry & lock audit", description: "30-day expiry exposure and inventory value at risk.", columns: [["batch_code", "Batch"], ["medicine_name", "Medicine"], ["supplier_name", "Supplier"], ["expiry_date", "Expiry"], ["days_to_expiry", "Days left"], ["expiry_status", "Status"], ["is_locked", "Locked"], ["current_stock", "Stock"], ["stock_value_at_risk", "Value at risk"]], money: ["stock_value_at_risk"] },
  B: { title: "Report B · Sellable FIFO stock", description: "Eligible units and next dispensable expiry by medicine.", columns: [["medicine_name", "Medicine"], ["category", "Category"], ["unit_price", "Unit price"], ["sellable_fifo_units", "Sellable units"], ["next_dispensable_expiry", "Next expiry"], ["sellable_inventory_value", "Sellable value"]], money: ["unit_price", "sellable_inventory_value"] },
  C: { title: "Report C · Recent sales & traceability", description: "Last 30 days of transactions, with batch and supplier detail.", columns: [["sale_id", "Sale"], ["sale_date", "Date"], ["customer_name", "Customer"], ["medicine_name", "Medicine"], ["batch_code", "Batch"], ["supplier_name", "Supplier"], ["quantity_sold", "Qty"], ["unit_price", "Unit price"], ["subtotal", "Subtotal"], ["total_amount", "Sale total"]], money: ["unit_price", "subtotal", "total_amount"] },
};

let activeReport = "A";
let catalog = [];
let previewDataActive = false;

function role() {
  return roleSelect.value;
}

function addLog(title, status, detail, sqlText = "") {
  const empty = logList.querySelector(".log-empty");
  if (empty) empty.remove();
  const entry = document.createElement("article");
  entry.className = `log-entry ${status}`;
  const time = new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
  const heading = document.createElement("div");
  heading.className = "log-entry-heading";
  const titleNode = document.createElement("strong");
  titleNode.textContent = previewDataActive ? `Sample data · ${title}` : title;
  const state = document.createElement("span");
  state.className = "log-status";
  state.textContent = status.toUpperCase();
  const timeNode = document.createElement("time");
  timeNode.textContent = time;
  heading.append(titleNode, state, timeNode);
  entry.append(heading);
  if (detail) {
    const detailNode = document.createElement("p");
    detailNode.textContent = detail;
    entry.append(detailNode);
  }
  if (sqlText) {
    const code = document.createElement("code");
    code.textContent = previewDataActive
      ? `-- PREVIEW ONLY: illustrative SQL; not executed against PostgreSQL.\n${sqlText}`
      : sqlText;
    entry.append(code);
  }
  logList.prepend(entry);
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      "X-MediGuard-Role": role(),
      ...(options.headers || {}),
    },
  });
  const body = await response.json();
  if (body.demo === true) previewDataActive = true;
  if (!response.ok) {
    const error = new Error(body.error || `Request failed (${response.status})`);
    error.body = body;
    error.status = response.status;
    throw error;
  }
  return body;
}

function showError(title, error) {
  addLog(title, "error", error.message, error.body?.sql || error.body?.detail || "");
  if (error.status === 403) addLog("RBAC policy", "blocked", error.message);
}

function setConnection(connected, label, preview = false) {
  previewDataActive = preview;
  document.querySelector("#connection-dot").classList.toggle("online", connected);
  document.querySelector("#connection-dot").classList.toggle("preview", preview);
  document.querySelector("#connection-label").textContent = preview ? "Sample data" : connected ? "Connected" : "Database offline";
  document.querySelector("#database-name").textContent = preview ? "PREVIEW DATASET" : label || (connected ? "PostgreSQL" : "Set MEDIGUARD_DATABASE_URL");
  document.querySelector("#mode-badge").classList.toggle("hidden", !preview);
  document.querySelector("#console-mode-label").textContent = preview ? "PREVIEW · NO DATABASE" : "LIVE DATABASE FEEDBACK";
  document.querySelector("#qa-mode-description").textContent = preview
    ? "Six preview checks illustrate expiry, FIFO, rollback and role-policy scenarios."
    : "Six live checks. Fixtures run in a transaction and are rolled back when complete.";
  document.querySelector("#qa-safe-title").textContent = preview ? "Preview results" : "Safe to run";
  document.querySelector("#qa-safe-description").textContent = preview
    ? "These results are illustrative; no database rows are created, changed or rolled back."
    : "QA data and successful checkout changes are rolled back; existing pharmacy records are left unchanged.";
  document.querySelector("#expiry-rule-description").textContent = preview
    ? "Sample batches show the intended 30-day lock and FIFO exclusion behavior."
    : " Batches expiring in 30 days or less are automatically locked by the database trigger and excluded from FIFO checkout.";
  document.querySelector("#inventory-mode-info").textContent = preview
    ? "Sample inventory illustrates expiry classification and stock lock behavior."
    : "Expiry classification and stock lock state are enforced by PostgreSQL.";
  document.querySelector("#batch-trigger-description").textContent = preview
    ? "The sample inventory applies the intended expiry rule when a batch is added."
    : "Database trigger classifies the new batch on insert.";
  document.querySelector("#checkout-mode-info").textContent = preview
    ? "Sample checkout applies FIFO to eligible inventory; no database is changed."
    : "Sellable batches are locked in expiry order before stock is deducted.";
  document.querySelector("#checkout-atomic-copy").textContent = preview
    ? "Preview checkout models atomic stock movement. An insufficient cart leaves sample stock unchanged; no database rows are written."
    : "Each checkout runs as one database transaction. If any cart line cannot be fulfilled, the safe procedure rolls back every stock deduction and sale row.";
  document.querySelector("#report-mode-info").textContent = preview
    ? "Reports are calculated from the sample pharmacy dataset."
    : "Live report queries against the PostgreSQL ledger.";
  document.querySelector("#footer-mode").textContent = preview
    ? "Sample dataset · preview only"
    : "PostgreSQL-backed operations console";
}

function fmt(value) {
  if (value === null || value === undefined || value === "") return "—";
  return String(value);
}

function money(value) {
  const number = Number(value);
  return Number.isFinite(number) ? `₹${number.toFixed(2)}` : "—";
}

function bufferCount(plan) {
  const result = Array.isArray(plan) ? plan[0] : plan;
  const root = result?.Plan || {};
  const planning = result?.Planning || {};
  const execution = result?.Execution || {};
  return Number(root["Shared Hit Blocks"] || 0)
    + Number(root["Shared Read Blocks"] || 0)
    + Number(planning["Shared Hit Blocks"] || 0)
    + Number(planning["Shared Read Blocks"] || 0)
    + Number(execution["Shared Hit Blocks"] || 0)
    + Number(execution["Shared Read Blocks"] || 0);
}

function badge(status, locked) {
  const css = status === "EXPIRED" ? "danger" : status === "EXPIRING_SOON" ? "warning" : "success";
  return `<span class="status-badge ${css}">${status}</span>${locked ? '<span class="lock-marker">LOCKED</span>' : ""}`;
}

function updateRoleUI() {
  document.querySelector("#greeting-role").textContent = roleLabels[role()].split(" /")[0];
  document.querySelector("#role-avatar").textContent = roleLabels[role()][0];
  document.querySelectorAll("[data-action='admin']").forEach((node) => {
    node.classList.toggle("dimmed", role() !== "admin");
  });
  document.querySelector("#batch-form button").disabled = role() !== "admin";
  document.querySelector("#run-qa").disabled = role() !== "admin";
  document.querySelectorAll(".unlock-button").forEach((button) => {
    button.disabled = role() !== "admin";
  });
  document.querySelectorAll(".checkout-submit, #add-cart-line, #expiry-refresh").forEach((button) => {
    button.disabled = role() === "auditor";
  });
}

function setView(name) {
  document.querySelectorAll(".view").forEach((view) => view.classList.toggle("active", view.id === `view-${name}`));
  document.querySelectorAll(".nav-link").forEach((button) => button.classList.toggle("active", button.dataset.view === name));
  document.querySelector("#page-title").textContent = {
    overview: "Overview", inventory: "Inventory", checkout: "FIFO checkout",
    reports: "Reports", plans: "Query plans", qa: "QA suite",
  }[name];
  if (name === "inventory") {
    loadBatches();
    loadCatalog();
  }
  if (name === "checkout") loadCatalog();
  if (name === "reports") runReport(activeReport);
}

function renderOverview(data) {
  const metric = data.metrics;
  document.querySelector("#metric-medicines").textContent = fmt(metric.medicines);
  document.querySelector("#metric-batches").textContent = fmt(metric.batches);
  document.querySelector("#metric-units").textContent = fmt(metric.units);
  document.querySelector("#metric-locked").textContent = fmt(metric.locked_batches);
  document.querySelector("#metric-sales").textContent = fmt(metric.sales_today);
  const rows = data.batches.map((batch) => `
    <tr>
      <td><span class="batch-code">${escapeHtml(batch.batch_code)}</span><small>#${batch.batch_id}</small></td>
      <td>${escapeHtml(batch.medicine_name)}</td>
      <td>${fmt(batch.expiry_date)}<small>${batch.days_to_expiry} days</small></td>
      <td>${batch.current_stock} units</td>
      <td>${badge(batch.expiry_status, false)}</td>
      <td>${batch.is_locked ? '<span class="lock-marker">LOCKED</span>' : '<span class="unlocked">UNLOCKED</span>'}</td>
    </tr>`).join("");
  document.querySelector("#overview-batches").innerHTML = rows || '<tr><td colspan="6" class="empty">No inventory batches found.</td></tr>';
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (char) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[char]);
}

async function loadOverview() {
  try {
    const [health, data] = await Promise.all([api("/api/health"), api("/api/overview")]);
    setConnection(health.connected, health.database, health.demo === true);
    renderOverview(data);
  } catch (error) {
    setConnection(false);
    showError("Dashboard load", error);
    document.querySelector("#overview-batches").innerHTML = `<tr><td colspan="6" class="empty">${escapeHtml(error.message)}</td></tr>`;
  }
}

async function loadCatalog() {
  try {
    const [catalogResult, supplierResult] = await Promise.all([api("/api/catalog"), api("/api/suppliers")]);
    catalog = catalogResult.medicines;
    const medicineSelect = document.querySelector("#batch-medicine");
    medicineSelect.innerHTML = catalog.map((item) => `<option value="${item.medicine_id}">${escapeHtml(item.medicine_name)}</option>`).join("");
    const suppliers = supplierResult.suppliers;
    document.querySelector("#batch-supplier").innerHTML = suppliers.map((supplier) => `<option value="${supplier.supplier_id}">${escapeHtml(supplier.supplier_name)}</option>`).join("");
    if (!suppliers.length) document.querySelector("#batch-supplier").innerHTML = '<option value="">Add a supplier in the database first</option>';
    if (!document.querySelector("#cart-lines").children.length) addCartLine();
    else refreshCartOptions();
  } catch (error) {
    showError("Catalog load", error);
  }
}

async function loadBatches() {
  try {
    const data = await api("/api/batches");
    document.querySelector("#batch-count").textContent = `${data.batches.length} batches`;
    const rows = data.batches.map((batch) => `
      <tr>
        <td><span class="batch-code">${escapeHtml(batch.batch_code)}</span><small>#${batch.batch_id}</small></td>
        <td>${escapeHtml(batch.medicine_name)}<small>${escapeHtml(batch.supplier_name)}</small></td>
        <td>${fmt(batch.expiry_date)}<small>${batch.days_to_expiry} days remaining</small></td>
        <td>${batch.current_stock} / ${batch.quantity_received}</td>
        <td>${badge(batch.expiry_status, false)}</td>
        <td>${batch.is_locked ? '<span class="lock-marker">LOCKED</span>' : '<span class="unlocked">UNLOCKED</span>'}</td>
        <td>${batch.is_locked ? `<button class="table-action unlock-button" data-batch="${batch.batch_id}" ${role() !== "admin" ? "disabled" : ""}>Attempt unlock</button>` : ""}</td>
      </tr>`).join("");
    document.querySelector("#batch-rows").innerHTML = rows || '<tr><td colspan="7" class="empty">No batches in the ledger.</td></tr>';
    document.querySelectorAll(".unlock-button").forEach((button) => button.addEventListener("click", () => tryUnlock(button.dataset.batch)));
  } catch (error) {
    showError("Inventory load", error);
    document.querySelector("#batch-rows").innerHTML = `<tr><td colspan="7" class="empty">${escapeHtml(error.message)}</td></tr>`;
  }
}

async function tryUnlock(batchId) {
  try {
    const result = await api(`/api/batches/${batchId}/unlock`, { method: "POST", body: "{}" });
    addLog("Batch unlock", "success", `${result.batch.batch_code} is now unlocked.`, result.sql);
  } catch (error) {
    showError("Expiry trigger blocked unlock", error);
  }
  loadBatches();
}

async function runReport(reportId) {
  activeReport = reportId;
  const definition = reportDefinitions[reportId];
  document.querySelector("#report-title").textContent = definition.title;
  document.querySelector("#report-description").textContent = definition.description;
  document.querySelectorAll(".report-tab").forEach((button) => button.classList.toggle("active", button.dataset.report === reportId));
  try {
    const data = await api(`/api/reports/${reportId}`);
    const headers = definition.columns.map(([, title]) => `<th>${escapeHtml(title)}</th>`).join("");
    const rows = data.rows.map((row) => `<tr>${definition.columns.map(([key]) => {
      let value = row[key];
      if (definition.money.includes(key)) value = money(value);
      if (typeof value === "boolean") value = value ? "Yes" : "No";
      return `<td>${escapeHtml(fmt(value))}</td>`;
    }).join("")}</tr>`).join("");
    document.querySelector("#report-head").innerHTML = `<tr>${headers}</tr>`;
    document.querySelector("#report-rows").innerHTML = rows || `<tr><td colspan="${definition.columns.length}" class="empty">No rows returned.</td></tr>`;
    addLog(`Report ${reportId} executed`, "success", `${data.rows.length} rows returned.`, data.sql);
  } catch (error) {
    showError(`Report ${reportId}`, error);
    document.querySelector("#report-rows").innerHTML = `<tr><td class="empty">${escapeHtml(error.message)}</td></tr>`;
  }
}

function addCartLine() {
  const line = document.createElement("div");
  line.className = "cart-line";
  line.innerHTML = `<select class="cart-medicine" aria-label="Cart medicine"></select><span class="available-count">0 units</span><input class="cart-quantity" aria-label="Quantity" type="number" min="1" value="1"><button type="button" class="remove-line" aria-label="Remove item">×</button>`;
  document.querySelector("#cart-lines").append(line);
  line.querySelector(".remove-line").addEventListener("click", () => {
    line.remove();
    updateCartEstimate();
  });
  line.querySelector(".cart-medicine").addEventListener("change", updateCartLine);
  line.querySelector(".cart-quantity").addEventListener("input", updateCartEstimate);
  refreshCartOptions();
}

function refreshCartOptions() {
  document.querySelectorAll(".cart-line").forEach((line) => {
    const select = line.querySelector(".cart-medicine");
    const previous = select.value;
    select.innerHTML = catalog.map((item) => `<option value="${item.medicine_id}">${escapeHtml(item.medicine_name)} · ${money(item.unit_price)}</option>`).join("");
    if (previous && catalog.some((item) => String(item.medicine_id) === previous)) select.value = previous;
    updateCartLine({ target: select });
  });
}

function updateCartLine(event) {
  const line = event.target.closest(".cart-line");
  const medicine = catalog.find((item) => String(item.medicine_id) === line.querySelector(".cart-medicine").value);
  line.querySelector(".available-count").textContent = `${medicine?.available_stock ?? 0} units`;
  updateCartEstimate();
}

function updateCartEstimate() {
  const total = [...document.querySelectorAll(".cart-line")].reduce((sum, line) => {
    const medicine = catalog.find((item) => String(item.medicine_id) === line.querySelector(".cart-medicine").value);
    return sum + (Number(medicine?.unit_price || 0) * Number(line.querySelector(".cart-quantity").value || 0));
  }, 0);
  document.querySelector("#estimated-total").textContent = money(total);
}

async function submitCheckout(event) {
  event.preventDefault();
  const items = [...document.querySelectorAll(".cart-line")].map((line) => ({
    medicine_id: Number(line.querySelector(".cart-medicine").value),
    quantity: Number(line.querySelector(".cart-quantity").value),
  }));
  try {
    const result = await api("/api/checkout", {
      method: "POST",
      body: JSON.stringify({ customer_name: document.querySelector("#customer-name").value, items }),
    });
    addLog(
      previewDataActive ? `Sale #${result.sale_id} previewed` : `Sale #${result.sale_id} committed`,
      "success",
      previewDataActive
        ? `Sample FIFO checkout total ${money(result.total)}; no database was changed.`
        : `FIFO checkout total ${money(result.total)}.`,
      result.sql,
    );
    const box = document.querySelector("#checkout-result");
    box.classList.remove("hidden", "error-result");
    box.innerHTML = `<strong>${previewDataActive ? "Sample sale" : "Sale"} #${result.sale_id} ${previewDataActive ? "preview" : "committed"} · ${money(result.total)}</strong>${result.items.map((item) => `<div>${escapeHtml(item.medicine_name)} · ${escapeHtml(item.batch_code)} · ${item.quantity_sold} units · ${money(item.subtotal)}</div>`).join("")}`;
    await loadCatalog();
    loadOverview();
  } catch (error) {
    showError("Checkout rolled back", error);
    const box = document.querySelector("#checkout-result");
    box.classList.remove("hidden");
    box.classList.add("error-result");
    box.textContent = previewDataActive
      ? `${error.message} Sample stock remains unchanged.`
      : `${error.message} No sale or stock deduction was committed.`;
  }
}

async function runPlans() {
  const button = document.querySelector("#run-plans");
  button.disabled = true;
  try {
    const result = await api("/api/plans");
    document.querySelector("#baseline-plan").textContent = JSON.stringify(result.baseline, null, 2);
    document.querySelector("#optimized-plan").textContent = JSON.stringify(result.optimized, null, 2);
    const before = bufferCount(result.baseline);
    const after = bufferCount(result.optimized);
    const summary = document.querySelector("#plan-summary");
    summary.classList.remove("hidden");
    summary.textContent = `Buffers touched · baseline ${before} · index path ${after}. ${result.note}`;
    addLog("Execution plans analyzed", "success", `Buffer blocks: baseline ${before}, index path ${after}.`, result.sql);
  } catch (error) {
    showError("EXPLAIN analysis", error);
  } finally {
    button.disabled = false;
  }
}

async function runQA() {
  const button = document.querySelector("#run-qa");
  button.disabled = true;
  document.querySelector("#qa-score").textContent = "RUNNING";
  try {
    const result = await api("/api/qa", { method: "POST", body: "{}" });
    result.steps.forEach((step) => addLog(step.id, step.passed ? "success" : "error", `${step.title}: ${step.detail}`));
    const score = document.querySelector("#qa-score");
    score.textContent = previewDataActive
      ? `${result.passed}/${result.total} PASSED · PREVIEW ONLY`
      : `${result.passed}/${result.total} PASSED · ROLLED BACK`;
    score.classList.toggle("failed", result.passed !== result.total);
    document.querySelectorAll(".qa-row").forEach((row, index) => {
      const step = result.steps[index];
      row.classList.toggle("passed", step.passed);
      row.classList.toggle("failed", !step.passed);
      row.querySelector(".qa-state").textContent = step.passed ? "✓" : "!";
      row.querySelector(".qa-detail").textContent = step.detail;
    });
  } catch (error) {
    showError("QA suite", error);
    document.querySelector("#qa-score").textContent = "FAILED TO RUN";
  } finally {
    button.disabled = role() !== "admin";
  }
}

document.querySelectorAll(".nav-link").forEach((button) => button.addEventListener("click", () => setView(button.dataset.view)));
document.querySelectorAll("[data-go]").forEach((button) => button.addEventListener("click", () => setView(button.dataset.go)));
document.querySelector("#role-select").addEventListener("change", () => {
  localStorage.setItem("mediguard-role", role());
  updateRoleUI();
  addLog("Active role switched", "info", previewDataActive
    ? `Console role set to ${roleLabels[role()]}. Sample actions use preview role permissions.`
    : `Console role set to ${roleLabels[role()]}. Database actions will run under this PostgreSQL role.`);
  loadOverview();
  if (document.querySelector("#view-inventory").classList.contains("active")) loadBatches();
  if (document.querySelector("#view-checkout").classList.contains("active")) loadCatalog();
});
document.querySelector("#refresh-button").addEventListener("click", loadOverview);
document.querySelector("#batch-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = Object.fromEntries(new FormData(event.currentTarget).entries());
  form.medicine_id = Number(form.medicine_id);
  form.supplier_id = Number(form.supplier_id);
  form.quantity_received = Number(form.quantity_received);
  form.current_stock = Number(form.current_stock);
  try {
    const result = await api("/api/batches", { method: "POST", body: JSON.stringify(form) });
    addLog("Batch inserted", "success", `${result.batch.batch_code}: ${result.batch.expiry_status}, locked=${result.batch.is_locked}.`, result.sql);
    event.currentTarget.reset();
    await loadBatches();
    loadOverview();
  } catch (error) {
    showError("Batch insert / expiry trigger", error);
  }
});
document.querySelector("#expiry-refresh").addEventListener("click", async () => {
  try {
    const result = await api("/api/refresh", { method: "POST", body: "{}" });
    addLog("Expiry refresh complete", "success", `${result.refreshed} batch rows re-evaluated.`, result.sql);
    await loadBatches();
  } catch (error) {
    showError("Expiry refresh", error);
  }
});
document.querySelector("#add-cart-line").addEventListener("click", addCartLine);
document.querySelector("#checkout-form").addEventListener("submit", submitCheckout);
document.querySelectorAll(".report-tab").forEach((button) => button.addEventListener("click", () => runReport(button.dataset.report)));
document.querySelector("#run-report").addEventListener("click", () => runReport(activeReport));
document.querySelector("#run-plans").addEventListener("click", runPlans);
document.querySelector("#run-qa").addEventListener("click", runQA);
document.querySelector("#clear-log").addEventListener("click", () => {
  logList.innerHTML = '<div class="log-empty">Database actions and errors will appear here.</div>';
});

const savedRole = localStorage.getItem("mediguard-role");
if (savedRole && Object.hasOwn(roleLabels, savedRole)) roleSelect.value = savedRole;
updateRoleUI();
loadOverview();
