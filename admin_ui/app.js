(() => {
  const token = new URLSearchParams(location.search).get("token") || "";
  const headers = () => {
    const h = { "Content-Type": "application/json" };
    if (token) h["X-Admin-Token"] = token;
    return h;
  };

  let schema = { global: [], project: [] };
  let currentProject = null;

  const $ = (id) => document.getElementById(id);
  const msg = (id, text, err = false) => {
    const el = $(id);
    el.textContent = text || "";
    el.classList.toggle("err", !!err);
  };

  const fieldInput = (key, value, isProvider = false) => {
    const label = document.createElement("label");
    label.textContent = key;
    let input;
    if (isProvider) {
      input = document.createElement("select");
      for (const p of ["github", "gitee", "gitlab", "gitcode"]) {
        const o = document.createElement("option");
        o.value = p;
        o.textContent = p;
        if (p === (value || "github")) o.selected = true;
        input.appendChild(o);
      }
    } else if (key === "WATCH_PRS" || key === "AUTO_PUBLISH" || key === "ADMIN_ENABLE" || key === "ENABLED") {
      input = document.createElement("select");
      for (const p of ["true", "false"]) {
        const o = document.createElement("option");
        o.value = p;
        o.textContent = p;
        if (String(value || "true") === p) o.selected = true;
        input.appendChild(o);
      }
    } else {
      input = document.createElement("input");
      input.value = value ?? "";
    }
    input.name = key;
    label.appendChild(input);
    return label;
  };

  const fillForm = (form, fields, data) => {
    form.innerHTML = "";
    for (const key of fields) {
      form.appendChild(fieldInput(key, data[key] ?? "", key === "PROVIDER"));
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

  const load = async () => {
    const res = await fetch("/api/config", { headers: headers() });
    if (!res.ok) throw new Error(await res.text());
    const data = await res.json();
    schema = data.schema;
    fillForm($("form-global"), schema.global, data.global || {});
    const ul = $("project-list");
    ul.innerHTML = "";
    for (const p of data.projects || []) {
      const li = document.createElement("li");
      const name = p.NAME || p._file;
      li.textContent = `${name} (${p.PROVIDER || "?"}) ${p.ENABLED === "false" ? "[disabled]" : ""}`;
      li.onclick = () => openProject(name);
      ul.appendChild(li);
    }
  };

  const openProject = async (name) => {
    const res = await fetch("/api/projects/" + encodeURIComponent(name), { headers: headers() });
    if (!res.ok) {
      msg("project-msg", "加载失败", true);
      return;
    }
    const data = await res.json();
    currentProject = data.NAME || name;
    fillForm($("form-project"), schema.project, data);
    $("form-project").classList.remove("hidden");
    $("project-actions").classList.remove("hidden");
    msg("project-msg", "编辑: " + currentProject);
  };

  $("tab-global").onclick = () => {
    $("tab-global").classList.add("active");
    $("tab-projects").classList.remove("active");
    $("view-global").classList.remove("hidden");
    $("view-projects").classList.add("hidden");
  };
  $("tab-projects").onclick = () => {
    $("tab-projects").classList.add("active");
    $("tab-global").classList.remove("active");
    $("view-projects").classList.remove("hidden");
    $("view-global").classList.add("hidden");
  };

  $("save-global").onclick = async () => {
    const res = await fetch("/api/global", {
      method: "PUT",
      headers: headers(),
      body: JSON.stringify(formData($("form-global"))),
    });
    const body = await res.json().catch(() => ({}));
    msg("global-msg", res.ok ? "已保存并请求 daemon 重载" : body.error || "失败", !res.ok);
  };

  $("new-project").onclick = () => {
    const name = prompt("项目 NAME（字母数字_-）");
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
    $("form-project").classList.remove("hidden");
    $("project-actions").classList.remove("hidden");
    $("form-project").dataset.create = "1";
    msg("project-msg", "新建: " + name + "（保存后生效）");
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
      msg("project-msg", "已保存并请求重载");
      await load();
    } else {
      msg("project-msg", body.error || "失败", true);
    }
  };

  $("delete-project").onclick = async () => {
    if (!currentProject) return;
    if (!confirm("确认删除项目配置 " + currentProject + "？不会删除历史 run。")) return;
    const res = await fetch("/api/projects/" + encodeURIComponent(currentProject), {
      method: "DELETE",
      headers: headers(),
    });
    const body = await res.json().catch(() => ({}));
    if (res.ok) {
      currentProject = null;
      $("form-project").classList.add("hidden");
      $("project-actions").classList.add("hidden");
      msg("project-msg", "已删除");
      await load();
    } else {
      msg("project-msg", body.error || "失败", true);
    }
  };

  load().catch((e) => msg("global-msg", String(e), true));
})();
