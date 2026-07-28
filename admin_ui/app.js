(() => {
  const token = new URLSearchParams(location.search).get("token") || "";
  const headers = () => {
    const h = { "Content-Type": "application/json" };
    if (token) h["X-Admin-Token"] = token;
    return h;
  };

  let schema = { global: [], project: [], groups: {} };
  let currentProject = null;
  let liveTimer = null;
  let liveTailTimer = null;
  let liveSel = null; // {project, file}
  let liveOffset = 0;
  let liveFollowing = true;

  const BOOL_KEYS = new Set(["WATCH_PRS", "AUTO_PUBLISH", "ADMIN_ENABLE", "ENABLED"]);

  const $ = (id) => document.getElementById(id);
  const msg = (id, text, err = false) => {
    const el = $(id);
    el.textContent = text || "";
    el.classList.toggle("err", !!err);
  };

  const setTab = (which) => {
    const tabs = ["live", "global", "projects"];
    for (const t of tabs) {
      const on = which === t;
      const btn = $("tab-" + t);
      const view = $("view-" + t);
      btn.classList.toggle("active", on);
      btn.setAttribute("aria-selected", String(on));
      view.classList.toggle("hidden", !on);
    }
    if (which === "live") startLive();
    else stopLive();
  };

  const stopLive = () => {
    if (liveTimer) {
      clearInterval(liveTimer);
      liveTimer = null;
    }
    if (liveTailTimer) {
      clearInterval(liveTailTimer);
      liveTailTimer = null;
    }
  };

  const shortSha = (s) => (s && s.length > 8 ? s.slice(0, 8) : s || "");

  const selectLive = (item) => {
    liveSel = item ? { project: item.project, file: item.file } : null;
    liveOffset = 0;
    $("live-log").textContent = "";
    const work = !!liveSel;
    $("live-idle").classList.toggle("hidden", work);
    $("live-work").classList.toggle("hidden", !work);
    if (!work) return;
    $("live-title").textContent = item.project + " · " + (item.run_id || item.file);
    const bits = [item.kind, item.ref, shortSha(item.sha)].filter(Boolean);
    $("live-sub").textContent = bits.join(" · ") || item.file;
    $("live-status").textContent = "跟进中…";
    $("live-status").classList.remove("done");
    for (const li of $("live-list").children) {
      li.classList.toggle(
        "active",
        li.dataset.project === item.project && li.dataset.file === item.file
      );
    }
    pullTail();
  };

  const pullTail = async () => {
    if (!liveSel) return;
    const q =
      "/api/live/tail?project=" +
      encodeURIComponent(liveSel.project) +
      "&file=" +
      encodeURIComponent(liveSel.file) +
      "&offset=" +
      liveOffset;
    const res = await fetch(q, { headers: headers() });
    if (!res.ok) {
      $("live-status").textContent = "读取日志失败";
      return;
    }
    const body = await res.json();
    if (body.text) {
      const pre = $("live-log");
      pre.textContent += body.text;
      if (liveFollowing || $("live-autoscroll").checked) {
        pre.scrollTop = pre.scrollHeight;
      }
    }
    liveOffset = body.next_offset;
    if (body.done) {
      $("live-status").textContent = "已结束 · 完整日志仍可在此查看，结果见静态看板";
      $("live-status").classList.add("done");
    } else {
      $("live-status").textContent = "跟进中 · " + body.size + " bytes";
      $("live-status").classList.remove("done");
    }
  };

  const renderLiveList = (snap) => {
    const ul = $("live-list");
    const active = snap.active || [];
    $("live-empty").classList.toggle("hidden", active.length > 0);
    ul.innerHTML = "";
    for (const item of active) {
      const li = document.createElement("li");
      li.dataset.project = item.project;
      li.dataset.file = item.file;
      li.tabIndex = 0;
      li.setAttribute("role", "button");
      if (liveSel && liveSel.project === item.project && liveSel.file === item.file) {
        li.classList.add("active");
      }
      const nm = document.createElement("span");
      nm.className = "proj-name";
      nm.textContent = item.project;
      const meta = document.createElement("span");
      meta.className = "proj-meta";
      meta.textContent = [item.kind || "run", item.ref || "", shortSha(item.sha)]
        .filter(Boolean)
        .join(" · ");
      li.appendChild(nm);
      li.appendChild(meta);
      li.onclick = () => selectLive(item);
      li.onkeydown = (e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          selectLive(item);
        }
      };
      ul.appendChild(li);
    }
    if (liveSel) {
      const still = active.some((a) => a.project === liveSel.project && a.file === liveSel.file);
      if (!still && active.length) {
        // keep selection so user can read finished log; status updated by tail
      } else if (!still && !active.length && !$("live-work").classList.contains("hidden")) {
        // leave finished view until user clears / new run
      } else if (!liveSel && active.length) {
        selectLive(active[0]);
      }
    } else if (active.length === 1) {
      selectLive(active[0]);
    }
  };

  const refreshLive = async () => {
    const res = await fetch("/api/live", { headers: headers() });
    if (!res.ok) return;
    const snap = await res.json();
    const daemonEl = $("live-daemon");
    daemonEl.classList.toggle("on", snap.daemon === "running");
    daemonEl.classList.toggle("off", snap.daemon !== "running");
    daemonEl.querySelector(".live-pill-text").textContent =
      "守护进程 · " + (snap.daemon === "running" ? "运行中" : "未启动");
    $("live-pending").textContent = String(snap.pending || 0);
    $("live-active-n").textContent = String((snap.active || []).length);
    renderLiveList(snap);
  };

  const startLive = () => {
    stopLive();
    refreshLive().catch(() => {});
    liveTimer = setInterval(() => refreshLive().catch(() => {}), 1500);
    liveTailTimer = setInterval(() => {
      if (liveSel && !$("live-status").classList.contains("done")) {
        pullTail().catch(() => {});
      }
    }, 800);
  };

  const showProjectEditor = (show) => {
    $("project-placeholder").classList.toggle("hidden", show);
    $("project-work").classList.toggle("hidden", !show);
  };

  const fieldInput = (field, value) => {
    const key = field.key;
    const wrap = document.createElement("label");
    const title = document.createElement("span");
    title.className = "field-label";
    title.textContent = field.label || key;
    wrap.appendChild(title);

    const keyHint = document.createElement("span");
    keyHint.className = "field-key";
    keyHint.textContent = key;
    wrap.appendChild(keyHint);

    if (field.help) {
      const help = document.createElement("span");
      help.className = "field-help";
      help.textContent = field.help;
      wrap.appendChild(help);
    }

    let input;
    if (key === "PROVIDER") {
      input = document.createElement("select");
      for (const p of ["github", "gitee", "gitlab", "gitcode"]) {
        const o = document.createElement("option");
        o.value = p;
        o.textContent = p;
        if (p === (value || "github")) o.selected = true;
        input.appendChild(o);
      }
    } else if (BOOL_KEYS.has(key)) {
      input = document.createElement("select");
      for (const [v, t] of [
        ["true", "是"],
        ["false", "否"],
      ]) {
        const o = document.createElement("option");
        o.value = v;
        o.textContent = t;
        if (String(value || "true") === v) o.selected = true;
        input.appendChild(o);
      }
    } else {
      input = document.createElement("input");
      input.value = value ?? "";
    }
    input.name = key;
    wrap.appendChild(input);
    return wrap;
  };

  const fillForm = (form, fields, data) => {
    form.innerHTML = "";
    const groups = schema.groups || {};
    let i = 0;
    while (i < fields.length) {
      const g = fields[i].group || "";
      const chunk = [];
      while (i < fields.length && (fields[i].group || "") === g) {
        chunk.push(fields[i]);
        i++;
      }
      const title = groups[g] || g || "其它";
      if (g === "paths") {
        const details = document.createElement("details");
        details.className = "field-group";
        const summary = document.createElement("summary");
        summary.textContent = title;
        details.appendChild(summary);
        for (const f of chunk) {
          details.appendChild(fieldInput(f, data[f.key] ?? ""));
        }
        form.appendChild(details);
      } else {
        const section = document.createElement("div");
        section.className = "field-group";
        const h = document.createElement("h3");
        h.textContent = title;
        section.appendChild(h);
        for (const f of chunk) {
          section.appendChild(fieldInput(f, data[f.key] ?? ""));
        }
        form.appendChild(section);
      }
    }
  };

  const formData = (form) => {
    const out = {};
    for (const el of form.elements) {
      if (!el.name) continue;
      out[el.name] = el.value;
    }
    return out;
  };

  const markActive = (name) => {
    for (const li of $("project-list").children) {
      li.classList.toggle("active", li.dataset.name === name);
    }
  };

  const load = async () => {
    const res = await fetch("/api/config", { headers: headers() });
    if (!res.ok) throw new Error(await res.text());
    const data = await res.json();
    schema = data.schema;
    fillForm($("form-global"), schema.global, data.global || {});

    const projects = data.projects || [];
    const ul = $("project-list");
    ul.innerHTML = "";
    $("project-empty").classList.toggle("hidden", projects.length > 0);

    for (const p of projects) {
      const name = p.NAME || p._file;
      const li = document.createElement("li");
      li.dataset.name = name;
      li.tabIndex = 0;
      li.setAttribute("role", "button");

      const nm = document.createElement("span");
      nm.className = "proj-name";
      nm.textContent = name;

      const meta = document.createElement("span");
      meta.className = "proj-meta";
      meta.appendChild(document.createTextNode(p.PROVIDER || "?"));
      if (p.ENABLED === "false") {
        const off = document.createElement("span");
        off.className = "badge-off";
        off.textContent = "已禁用";
        meta.appendChild(off);
      }

      li.appendChild(nm);
      li.appendChild(meta);
      li.onclick = () => openProject(name);
      li.onkeydown = (e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          openProject(name);
        }
      };
      ul.appendChild(li);
    }

    if (currentProject) {
      const still = projects.some((p) => (p.NAME || p._file) === currentProject);
      if (still) markActive(currentProject);
      else {
        currentProject = null;
        showProjectEditor(false);
      }
    }
  };

  const openProject = async (name) => {
    const res = await fetch("/api/projects/" + encodeURIComponent(name), { headers: headers() });
    if (!res.ok) {
      msg("project-msg", "加载失败", true);
      showProjectEditor(true);
      return;
    }
    const data = await res.json();
    currentProject = data.NAME || name;
    $("form-project").dataset.create = "";
    fillForm($("form-project"), schema.project, data);
    $("project-title").textContent = currentProject;
    $("project-sub").textContent = "仓库、分支与执行脚本";
    showProjectEditor(true);
    markActive(currentProject);
    msg("project-msg", "");
  };

  $("tab-live").onclick = () => setTab("live");
  $("tab-global").onclick = () => setTab("global");
  $("tab-projects").onclick = () => setTab("projects");
  $("live-refresh").onclick = () => refreshLive().catch(() => {});
  $("live-autoscroll").onchange = (e) => {
    liveFollowing = e.target.checked;
    if (liveFollowing) {
      const pre = $("live-log");
      pre.scrollTop = pre.scrollHeight;
    }
  };

  $("save-global").onclick = async () => {
    const res = await fetch("/api/global", {
      method: "PUT",
      headers: headers(),
      body: JSON.stringify(formData($("form-global"))),
    });
    const body = await res.json().catch(() => ({}));
    msg("global-msg", res.ok ? "已保存并请求守护进程重载" : body.error || "失败", !res.ok);
  };

  const NAME_RE = /^[A-Za-z0-9_-]+$/;
  const dlg = $("dlg-new-project");
  const nameInput = $("new-project-name");

  const startCreate = (name) => {
    currentProject = name;
    const data = {
      NAME: name,
      PROVIDER: "github",
      BRANCHES: "main",
      WATCH_PRS: "true",
      ENABLED: "true",
      SCRIPT: "./scripts/ci.example.sh",
      TOKEN_ENV: "GITHUB_TOKEN",
    };
    fillForm($("form-project"), schema.project, data);
    $("form-project").dataset.create = "1";
    $("project-title").textContent = "新建 · " + name;
    $("project-sub").textContent = "填写后保存才会写入配置文件";
    showProjectEditor(true);
    markActive(null);
    setTab("projects");
    msg("project-msg", "尚未保存");
  };

  $("new-project").onclick = () => {
    nameInput.value = "";
    msg("new-project-err", "");
    dlg.showModal();
    nameInput.focus();
  };

  $("new-project-cancel").onclick = () => dlg.close();

  dlg.addEventListener("click", (e) => {
    if (e.target === dlg) dlg.close();
  });

  $("form-new-project").onsubmit = (e) => {
    e.preventDefault();
    const name = nameInput.value.trim();
    if (!name) {
      msg("new-project-err", "请填写项目名称", true);
      nameInput.focus();
      return;
    }
    if (!NAME_RE.test(name)) {
      msg("new-project-err", "仅字母数字、下划线、短横线", true);
      nameInput.focus();
      return;
    }
    dlg.close();
    startCreate(name);
  };

  $("save-project").onclick = async () => {
    const data = formData($("form-project"));
    const name = data.NAME || currentProject;
    const creating = $("form-project").dataset.create === "1";
    const res = await fetch(
      creating ? "/api/projects" : "/api/projects/" + encodeURIComponent(name),
      {
        method: creating ? "POST" : "PUT",
        headers: headers(),
        body: JSON.stringify(data),
      }
    );
    const body = await res.json().catch(() => ({}));
    if (res.ok) {
      $("form-project").dataset.create = "";
      currentProject = name;
      $("project-title").textContent = name;
      $("project-sub").textContent = "仓库、分支与执行脚本";
      msg("project-msg", "已保存并请求重载");
      await load();
      markActive(name);
    } else {
      msg("project-msg", body.error || "失败", true);
    }
  };

  $("delete-project").onclick = async () => {
    if (!currentProject) return;
    if (!confirm("确认删除项目配置「" + currentProject + "」？不会删除历史运行记录。")) return;
    const res = await fetch("/api/projects/" + encodeURIComponent(currentProject), {
      method: "DELETE",
      headers: headers(),
    });
    const body = await res.json().catch(() => ({}));
    if (res.ok) {
      currentProject = null;
      showProjectEditor(false);
      msg("project-msg", "");
      await load();
    } else {
      msg("project-msg", body.error || "失败", true);
    }
  };

  load().catch((e) => msg("global-msg", String(e), true));
  startLive();
})();
