(() => {
  const token = new URLSearchParams(location.search).get("token") || "";
  const headers = () => {
    const h = { "Content-Type": "application/json" };
    if (token) h["X-Admin-Token"] = token;
    return h;
  };

  let schema = { global: [], project: [], groups: {} };
  let currentProject = null;

  const BOOL_KEYS = new Set(["WATCH_PRS", "AUTO_PUBLISH", "ADMIN_ENABLE", "ENABLED"]);

  const $ = (id) => document.getElementById(id);
  const msg = (id, text, err = false) => {
    const el = $(id);
    el.textContent = text || "";
    el.classList.toggle("err", !!err);
  };

  const setTab = (which) => {
    const global = which === "global";
    $("tab-global").classList.toggle("active", global);
    $("tab-projects").classList.toggle("active", !global);
    $("tab-global").setAttribute("aria-selected", String(global));
    $("tab-projects").setAttribute("aria-selected", String(!global));
    $("view-global").classList.toggle("hidden", !global);
    $("view-projects").classList.toggle("hidden", global);
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

  $("tab-global").onclick = () => setTab("global");
  $("tab-projects").onclick = () => setTab("projects");

  $("save-global").onclick = async () => {
    const res = await fetch("/api/global", {
      method: "PUT",
      headers: headers(),
      body: JSON.stringify(formData($("form-global"))),
    });
    const body = await res.json().catch(() => ({}));
    msg("global-msg", res.ok ? "已保存并请求守护进程重载" : body.error || "失败", !res.ok);
  };

  $("new-project").onclick = () => {
    const name = prompt("项目名称（字母数字、下划线、短横线）");
    if (!name) return;
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
})();
