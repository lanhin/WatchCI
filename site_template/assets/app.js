(() => {
  const project = document.getElementById("filter-project");
  const status = document.getElementById("filter-status");
  const table = document.getElementById("runs-table");
  if (!table) return;
  const rows = [...table.querySelectorAll("tbody tr")];
  const apply = () => {
    const p = (project?.value || "").trim().toLowerCase();
    const s = (status?.value || "").trim().toLowerCase();
    for (const row of rows) {
      const cells = row.children;
      const proj = (cells[1]?.textContent || "").toLowerCase();
      const st = (cells[2]?.textContent || "").toLowerCase();
      row.style.display = (!p || proj.includes(p)) && (!s || st === s) ? "" : "none";
    }
  };
  project?.addEventListener("input", apply);
  status?.addEventListener("change", apply);
})();
