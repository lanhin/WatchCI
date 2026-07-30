(() => {
  const project = document.getElementById("filter-project");
  const status = document.getElementById("filter-status");
  const table = document.getElementById("runs-table");
  if (!table) return;

  const primaryRows = [...table.querySelectorAll("tbody tr.run-primary")];
  const historyRows = [...table.querySelectorAll("tbody tr.run-history")];
  const expanded = new Set();

  const historyFor = (group) => historyRows.filter((r) => r.dataset.group === group);

  const apply = () => {
    const p = (project?.value || "").trim().toLowerCase();
    const s = (status?.value || "").trim().toLowerCase();
    for (const row of primaryRows) {
      const proj = (row.dataset.project || "").toLowerCase();
      const st = (row.dataset.status || "").toLowerCase();
      const match = (!p || proj.includes(p)) && (!s || st === s);
      row.style.display = match ? "" : "none";
      const group = row.dataset.group;
      if (!group) continue;
      const open = match && expanded.has(group);
      const hist = historyFor(group);
      for (const h of hist) h.hidden = !open;
      const btn = row.querySelector(".group-toggle");
      if (btn) {
        btn.setAttribute("aria-expanded", open ? "true" : "false");
        btn.textContent = `${open ? "▼" : "▶"} ${hist.length}`;
      }
    }
  };

  table.addEventListener("click", (e) => {
    const btn = e.target.closest(".group-toggle");
    if (!btn) return;
    const group = btn.dataset.group;
    if (!group) return;
    if (expanded.has(group)) expanded.delete(group);
    else expanded.add(group);
    apply();
  });

  project?.addEventListener("input", apply);
  status?.addEventListener("change", apply);
})();
