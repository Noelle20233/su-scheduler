/* ═══════════════════════════════════════════════════════════════════════
 * Su Scheduler — WebUI 只读数据面（P3-05）
 * 安全约束（本文件必须始终遵守，禁止在注释/字符串中出现下列关键词）：
 *   - 不访问用户数据目录；不执行系统命令；不使用动态代码求值。
 *   - 数据一律经只读 Reader（IPC）获取；页面只 fetch 本地 API / bridge。
 *   - 所有动态内容用 textContent 渲染，绝不把数据拼进标签/属性字符串。
 *   - 特殊字符（尖括号标签、引号、换行）只会作为文本显示，不会注入 HTML/JS。
 * 数据源适配：
 *   - 生产（KernelSU WebUI Bridge）：window.suReader.read(op, params) →
 *     在 manager 侧执行 `su-scheduler webui <op> ...`（同一 CLI Reader）。
 *   - 主机/开发：fetch 相对路径 ./api?op=...（由 webroot 伺服桥接）。
 * ═══════════════════════════════════════════════════════════════════════ */
(function () {
  "use strict";

  var READ_OPS = ["GET_SUMMARY", "GET_TASK_DETAIL", "GET_TASK_EVENTS", "GET_DAEMON_LOG", "GET_TASK_LOG"];

  /* ── 数据读取适配器（统一入口；本文件内所有数据都经它）────────────── */
  function read(op, params) {
    if (READ_OPS.indexOf(op) < 0) {
      return Promise.reject(new Error("webui read-only: op not allowed"));
    }
    if (window.suReader && typeof window.suReader.read === "function") {
      return Promise.resolve(window.suReader.read(op, params || {}));
    }
    var qs = [];
    Object.keys(params || {}).forEach(function (k) {
      qs.push(encodeURIComponent(k) + "=" + encodeURIComponent(params[k]));
    });
    var url = "./api?op=" + encodeURIComponent(op) + (qs.length ? "&" + qs.join("&") : "");
    return fetch(url, { cache: "no-store" }).then(function (r) {
      return r.json().catch(function () { return { ok: false, error: "bad_json" }; });
    });
  }

  /* ── DOM 安全渲染 ───────────────────────────────────────────────────── */
  function el(tag, attrs) {
    var node = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        if (k === "text") { node.textContent = attrs[k]; }
        else if (k === "class") { node.className = attrs[k]; }
        else { node.setAttribute(k, attrs[k]); }
      });
    }
    return node;
  }
  function escText(s) { return String(s == null ? "" : s); }

  function card(label, value, cls) {
    var c = el("div", { class: "card " + (cls || "") });
    var l = el("div", { class: "card-label", text: escText(label) });
    var v = el("div", { class: "card-value", text: escText(value) });
    c.appendChild(l); c.appendChild(v);
    return c;
  }

  function offlineBanner() {
    var b = el("div", { class: "banner offline", text: "daemon 离线：无法读取数据（daemon_unavailable）。请确认 su-schedulerd 正在运行。" });
    return b;
  }

  /* ── 视图：Dashboard ────────────────────────────────────────────────── */
  function renderDashboard(data) {
    var view = document.getElementById("view");
    view.textContent = "";
    if (!data.ok) { view.appendChild(offlineBanner()); return; }
    var counts = data.counts || {};
    var grid = el("div", { class: "cards" });
    grid.appendChild(card("Total Tasks", counts.total || 0, "c-total"));
    grid.appendChild(card("Running", counts.running || 0, "c-running"));
    grid.appendChild(card("Healthy", counts.healthy || 0, "c-healthy"));
    grid.appendChild(card("Failed", counts.failed || 0, "c-failed"));
    grid.appendChild(card("Disabled", counts.disabled || 0, "c-disabled"));
    view.appendChild(grid);

    var mode = el("p", { class: "mode", text: "配置模式：" + escText(data.mode || "legacy") });
    view.appendChild(mode);

    var h = el("h2", { text: "Tasks" });
    view.appendChild(h);
    var list = el("table", { class: "tbl" });
    var thead = el("tr");
    ["ID", "名称", "状态", "Trigger", "Action", "Health", "最近运行", "重启次数"].forEach(function (t) {
      thead.appendChild(el("th", { text: t }));
    });
    list.appendChild(thead);
    (data.tasks || []).forEach(function (t) {
      var tr = el("tr");
      var a = el("a", { href: "#task/" + encodeURIComponent(t.id), text: escText(t.id) });
      var td0 = el("td"); td0.appendChild(a); tr.appendChild(td0);
      tr.appendChild(el("td", { text: escText(t.name) }));
      tr.appendChild(el("td", { class: "st st-" + escText(t.status), text: escText(t.status) }));
      tr.appendChild(el("td", { text: escText(t.trigger) }));
      tr.appendChild(el("td", { class: "mono", text: escText(t.action) }));
      tr.appendChild(el("td", { text: escText(t.health) }));
      tr.appendChild(el("td", { text: escText(t.last_run) }));
      tr.appendChild(el("td", { text: escText(t.restart_count) }));
      list.appendChild(tr);
    });
    view.appendChild(list);
    if (!(data.tasks || []).length) {
      view.appendChild(el("p", { class: "empty", text: "（空：暂无任务）" }));
    }
  }

  /* ── 视图：Task List ────────────────────────────────────────────────── */
  function renderTasks(data) {
    var view = document.getElementById("view");
    view.textContent = "";
    if (!data.ok) { view.appendChild(offlineBanner()); return; }
    var h = el("h2", { text: "Task List" });
    view.appendChild(h);
    var list = el("table", { class: "tbl" });
    var thead = el("tr");
    ["ID", "名称", "状态", "Trigger", "Action", "Health", "最近运行", "重启次数", "启用"].forEach(function (t) {
      thead.appendChild(el("th", { text: t }));
    });
    list.appendChild(thead);
    (data.tasks || []).forEach(function (t) {
      var tr = el("tr");
      var a = el("a", { href: "#task/" + encodeURIComponent(t.id), text: escText(t.id) });
      var td0 = el("td"); td0.appendChild(a); tr.appendChild(td0);
      tr.appendChild(el("td", { text: escText(t.name) }));
      tr.appendChild(el("td", { class: "st st-" + escText(t.status), text: escText(t.status) }));
      tr.appendChild(el("td", { text: escText(t.trigger) }));
      tr.appendChild(el("td", { class: "mono", text: escText(t.action) }));
      tr.appendChild(el("td", { text: escText(t.health) }));
      tr.appendChild(el("td", { text: escText(t.last_run) }));
      tr.appendChild(el("td", { text: escText(t.restart_count) }));
      tr.appendChild(el("td", { text: escText(t.enabled) }));
      list.appendChild(tr);
    });
    view.appendChild(list);
    if (!(data.tasks || []).length) {
      view.appendChild(el("p", { class: "empty", text: "（空：暂无任务）" }));
    }
  }

  /* ── 视图：Task Detail ──────────────────────────────────────────────── */
  function renderTaskDetail(data, id) {
    var view = document.getElementById("view");
    view.textContent = "";
    if (!data.ok) {
      if (data.error === "task_not_found") {
        view.appendChild(el("p", { class: "empty", text: "任务不存在或配置无效：" + escText(id) }));
      } else {
        view.appendChild(offlineBanner());
      }
      return;
    }
    var t = data.task || {};
    var h = el("h2", { text: "Task Detail — " + escText(t.id) });
    view.appendChild(h);
    var grid = el("div", { class: "cards" });
    grid.appendChild(card("状态", t.status, "c-running"));
    grid.appendChild(card("Trigger", t.trigger));
    grid.appendChild(card("Enabled", t.enabled));
    grid.appendChild(card("PID", t.pid));
    grid.appendChild(card("上次退出码", t.last_exit));
    grid.appendChild(card("上次启动", t.last_start));
    grid.appendChild(card("上次结束", t.last_end));
    grid.appendChild(card("重启次数", t.restart_count));
    grid.appendChild(card("运行次数", t.run_count));
    view.appendChild(grid);

    var info = el("dl", { class: "kv" });
    function kv(k, v) {
      info.appendChild(el("dt", { text: k }));
      info.appendChild(el("dd", { class: "mono", text: escText(v) }));
    }
    kv("name", t.name);
    kv("trigger", t.trigger);
    kv("action", t.action);
    kv("health.type", (t.health && t.health.type) || "");
    kv("health.target", (t.health && t.health.target) || "");
    kv("recovery.type", (t.recovery && t.recovery.type) || "");
    kv("source.type", (t.source && t.source.type) || "");
    kv("source.line", (t.source && t.source.line) || "");
    kv("source.raw", (t.source && t.source.raw) || "");
    view.appendChild(info);

    /* 运行历史（events） */
    var evBtn = el("button", { text: "加载运行历史 (events)" });
    evBtn.addEventListener("click", function () {
      read("GET_TASK_EVENTS", { id: t.id, lines: "50" }).then(function (ev) {
        renderEvents(ev, t.id);
      });
    });
    view.appendChild(evBtn);
  }

  function renderEvents(data, id) {
    var container = el("div");
    if (!data.ok) {
      container.appendChild(el("p", { class: "empty", text: "无事件（或读取失败）" }));
      document.getElementById("view").appendChild(container);
      return;
    }
    var note = el("p", { class: "note" });
    note.textContent = "total=" + escText(data.total) + " returned=" + escText(data.returned) +
      (data.truncated ? " — 日志已截断（仅显示最近 " + escText(data.returned) + " 行）" : "");
    container.appendChild(note);
    var pre = el("pre", { class: "log mono" });
    pre.textContent = (data.lines || []).join("\n");
    container.appendChild(pre);
    document.getElementById("view").appendChild(container);
  }

  /* ── 视图：Logs ─────────────────────────────────────────────────────── */
  function renderLogs() {
    var view = document.getElementById("view");
    view.textContent = "";
    var h = el("h2", { text: "Logs" });
    view.appendChild(h);
    var form = el("div", { class: "logform" });
    var sel = el("select");
    ["50", "100", "200", "500"].forEach(function (n) {
      var o = el("option", { value: n, text: n });
      sel.appendChild(o);
    });
    sel.value = "100";
    var typeSel = el("select");
    [["daemon", "Daemon 日志"], ["task", "Task 日志"]].forEach(function (pair) {
      var o = el("option", { value: pair[0], text: pair[1] });
      typeSel.appendChild(o);
    });
    var idInput = el("input", { type: "text", placeholder: "task id（Task 日志需要）" });
    var btn = el("button", { text: "加载" });
    btn.addEventListener("click", function () {
      var lines = sel.value;
      var kind = typeSel.value;
      var p = { lines: lines };
      if (kind === "task") {
        var tid = idInput.value.trim();
        if (!tid) { alert("请输入 task id"); return; }
        p.id = tid;
        read("GET_TASK_LOG", p).then(function (d) { renderLogBlock(d, "Task 日志 " + tid); });
      } else {
        read("GET_DAEMON_LOG", p).then(function (d) { renderLogBlock(d, "Daemon 日志"); });
      }
    });
    form.appendChild(el("span", { text: "类型: " })); form.appendChild(typeSel);
    form.appendChild(el("span", { text: " 行数: " })); form.appendChild(sel);
    form.appendChild(el("span", { text: "  task id: " })); form.appendChild(idInput);
    form.appendChild(btn);
    view.appendChild(form);
    /* 默认加载 daemon 日志 */
    read("GET_DAEMON_LOG", { lines: "100" }).then(function (d) { renderLogBlock(d, "Daemon 日志"); });
  }

  function renderLogBlock(data, title) {
    var view = document.getElementById("view");
    var block = el("div");
    var h = el("h3", { text: title });
    block.appendChild(h);
    if (!data.ok) {
      block.appendChild(el("p", { class: "empty", text: "读取失败：" + escText(data.error || "") }));
      view.appendChild(block);
      return;
    }
    var note = el("p", { class: "note" });
    note.textContent = "total=" + escText(data.total) + " returned=" + escText(data.returned) +
      (data.truncated ? " — 日志已截断（仅显示最近 " + escText(data.returned) + " 行）" : "");
    block.appendChild(note);
    var pre = el("pre", { class: "log mono" });
    pre.textContent = (data.lines || []).join("\n");
    block.appendChild(pre);
    view.appendChild(block);
  }

  /* ── 路由 ───────────────────────────────────────────────────────────── */
  function parseHash() {
    var hh = window.location.hash || "#dashboard";
    if (hh.indexOf("#task/") === 0) { return { view: "task", id: decodeURIComponent(hh.slice(6)) }; }
    return { view: hh.slice(1).split("?")[0] || "dashboard" };
  }

  function setBadge(ok) {
    var b = document.getElementById("daemon-badge");
    if (ok) { b.textContent = "daemon: online"; b.className = "badge online"; }
    else { b.textContent = "daemon: offline"; b.className = "badge offline"; }
  }

  function route() {
    var r = parseHash();
    document.querySelectorAll("#nav a").forEach(function (a) {
      a.classList.toggle("active", a.getAttribute("data-view") === r.view);
    });
    if (r.view === "tasks") {
      read("GET_SUMMARY", {}).then(function (d) { setBadge(!!d.ok); renderTasks(d); });
    } else if (r.view === "logs") {
      read("GET_DAEMON_LOG", { lines: "5" }).then(function (d) { setBadge(!!d.ok); });
      renderLogs();
    } else if (r.view === "task") {
      read("GET_TASK_DETAIL", { id: r.id }).then(function (d) { setBadge(!!d.ok); renderTaskDetail(d, r.id); });
      read("GET_TASK_DETAIL", { id: r.id }).then(function (d) { setBadge(!!d.ok); renderTaskDetail(d, r.id); });
    } else {
      read("GET_SUMMARY", {}).then(function (d) { setBadge(!!d.ok); renderDashboard(d); });
    }
  }

  window.addEventListener("hashchange", route);
  document.addEventListener("DOMContentLoaded", route);
})();
