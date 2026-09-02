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

  /* ── Task Editor（P3-06）────────────────────────────────────────────────── */
  var WRITE_OPS = ["GET_TASK_EDIT", "VALIDATE_TASK", "EDIT_TASK", "DELETE_TASK", "ENABLE_TASK", "DISABLE_TASK"];

  function b64encode(str) {
    try { return btoa(unescape(encodeURIComponent(str))); } catch (e) { return ""; }
  }
  function b64decode(b64) {
    try { return decodeURIComponent(escape(atob(b64))); } catch (e) { return ""; }
  }
  function write(op, params) {
    if (WRITE_OPS.indexOf(op) < 0) {
      return Promise.reject(new Error("editor: op not allowed"));
    }
    if (window.suWriter && typeof window.suWriter.write === "function") {
      return Promise.resolve(window.suWriter.write(op, params || {}));
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

  var TASK_FORM_SCHEMA = {
    steps: ["Basic", "Trigger", "Action", "Health", "Recovery", "Retry", "Advanced"],
    fields: {
      id:       { step: "Basic",    type: "text",   label: "ID",         placeholder: "task_myjob", required: true, min: 1, max: 64 },
      name:     { step: "Basic",    type: "text",   label: "Name",       placeholder: "My Task",    required: true, min: 1, max: 64 },
      enabled:  { step: "Basic",    type: "checkbox", label: "Enabled",  def: "1" },
      description: { step: "Basic", type: "text",   label: "Description", max: 256 },
      triggerType: { step: "Trigger", type: "select", label: "Trigger Type", def: "time",
        options: [
          ["boot", "Boot（开机）"],
          ["time", "Time（HH:MM 每日）"],
          ["weekly", "Weekly（每周）"],
          ["nweekly", "N-Weekly（每 N 周）"],
          ["monthly", "Monthly（每月）"],
          ["nmonthly", "N-Monthly（每 N 月）"],
          ["yearly", "Yearly（每年）"],
          ["boot_completed", "Boot Completed（未实现）"],
          ["delay", "Delay（未实现）"],
          ["interval", "Interval（未实现）"],
          ["cron", "Cron（未实现）"],
          ["oneshot", "One-shot（未实现）"]
        ],
        unimplemented: ["boot_completed", "delay", "interval", "cron", "oneshot"] },
      time:     { step: "Trigger", type: "text", label: "Time (HH:MM)",  placeholder: "08:30", pattern: "^[0-2][0-9]:[0-5][0-9]$" },
      weeklyDOW:{ step: "Trigger", type: "text", label: "Weekday (1=Mon..7=Sun)", pattern: "^[1-7]$" },
      weeklyTime:{ step: "Trigger", type: "text", label: "Time (HHMM)", placeholder: "0830", pattern: "^[0-9]{4}$" },
      nweeklyN: { step: "Trigger", type: "text", label: "Every N weeks", pattern: "^[0-9]+$", min: 1, max: 52 },
      monthlyDay:{ step: "Trigger", type: "text", label: "Day of month", pattern: "^[0-9]+$", min: 1, max: 31 },
      monthlyTime:{ step: "Trigger", type: "text", label: "Time (HHMM)", pattern: "^[0-9]{4}$" },
      nmonthlyN:{ step: "Trigger", type: "text", label: "Every N months", pattern: "^[0-9]+$", min: 1, max: 12 },
      nmonthlyDay:{ step: "Trigger", type: "text", label: "Day of month", pattern: "^[0-9]+$", min: 1, max: 31 },
      nmonthlyTime:{ step: "Trigger", type: "text", label: "Time (HHMM)", pattern: "^[0-9]{4}$" },
      yearlyTime:{ step: "Trigger", type: "text", label: "Time (HHMM)", pattern: "^[0-9]{4}$" },
      actionType: { step: "Action", type: "select", label: "Action Type", def: "command",
        options: [["command", "Command（Shell 命令）"], ["app", "App（结构化 App Action）"]] },
      command:  { step: "Action", type: "textarea", label: "Command",     placeholder: "echo hello", required: true, max: 2048 },
      appOp:    { step: "Action", type: "select", label: "App Op", def: "package",
        options: [["package", "package（启动包）"], ["activity", "activity（启动组件）"], ["broadcast", "broadcast（发送广播）"], ["service", "service（启动服务）"]] },
      appTarget:{ step: "Action", type: "text", label: "App Target", placeholder: "com.example.app", required: true, max: 256 },
      healthType:{ step: "Health", type: "select", label: "Health Type", def: "none",
        options: [["none", "None"], ["process", "Process"], ["port", "Port"]] },
      healthTarget:{ step: "Health", type: "text", label: "Health Target（进程名/PID 或端口）", max: 128 },
      recoveryType:{ step: "Recovery", type: "select", label: "Recovery Type", def: "none",
        options: [["none", "None"], ["restart", "Restart"], ["start", "Start"], ["stopstart", "Stop + Start"], ["script", "Script（绝对路径）"]] },
      recoveryScript:{ step: "Recovery", type: "text", label: "Recovery Script（绝对路径）", placeholder: "/data/local/tmp/recover.sh", max: 256 },
      retryMax:{ step: "Retry", type: "text", label: "Max Retry (0-100)", def: "0", pattern: "^[0-9]+$", min: 0, max: 100 },
      retryInterval:{ step: "Retry", type: "text", label: "Retry Interval sec (0-86400)", def: "60", pattern: "^[0-9]+$", min: 0, max: 86400 },
      retryCooldown:{ step: "Retry", type: "text", label: "Cooldown sec (0-86400)", def: "0", pattern: "^[0-9]+$", min: 0, max: 86400 },
      timeout:{ step: "Advanced", type: "text", label: "Timeout sec (0-86400, 0=unlimited)", def: "0", pattern: "^[0-9]+$", min: 0, max: 86400 },
      environment:{ step: "Advanced", type: "text", label: "Environment (K=V,K=V)", max: 512 },
      concurrency:{ step: "Advanced", type: "text", label: "Concurrency (0-100, 0=unlimited)", def: "0", pattern: "^[0-9]+$", min: 0, max: 100 },
      logging:{ step: "Advanced", type: "text", label: "Logging lines (0-1000000)", def: "0", pattern: "^[0-9]+$", min: 0, max: 1000000 }
    }
  };

  function fieldDef(key) { return TASK_FORM_SCHEMA.fields[key]; }
  function isUnimpl(triggerType) {
    return TASK_FORM_SCHEMA.fields.triggerType.unimplemented.indexOf(triggerType) >= 0;
  }

  function parseTaskContent(content) {
    var map = {};
    String(content || "").split("\n").forEach(function (line) {
      var eq = line.indexOf("=");
      if (line.charAt(0) === "#" || eq < 1) { return; }
      map[line.slice(0, eq)] = line.slice(eq + 1);
    });
    return map;
  }

  function taskContentToForm(map) {
    var v = {};
    v.id = map.id || "";
    v.name = map.name || "";
    v.enabled = map.enabled === "0" ? "0" : "1";
    v.description = map.description || "";
    var trig = map.trigger || "time";
    if (trig === "boot") { v.triggerType = "boot"; }
    else if (/^[0-9]{1,2}:[0-9]{2}$/.test(trig)) { v.triggerType = "time"; v.time = trig; }
    else if (/^weekly:/.test(trig)) { v.triggerType = "weekly"; var wp = trig.split(":"); v.weeklyDOW = wp[1]; v.weeklyTime = wp[2]; }
    else if (/^nweekly:/.test(trig)) { v.triggerType = "nweekly"; var nw = trig.split(":"); v.nweeklyN = nw[1]; v.weeklyDOW = nw[2]; v.weeklyTime = nw[3]; }
    else if (/^monthly:/.test(trig)) { v.triggerType = "monthly"; var mp = trig.split(":"); v.monthlyDay = mp[1]; v.monthlyTime = mp[2]; }
    else if (/^nmonthly:/.test(trig)) { v.triggerType = "nmonthly"; var nm = trig.split(":"); v.nmonthlyN = nm[1]; v.nmonthlyDay = nm[2]; v.nmonthlyTime = nm[3]; }
    else if (/^yearly:/.test(trig)) { v.triggerType = "yearly"; var yp = trig.split(":"); v.yearlyTime = (yp.length === 4) ? (yp[1] + yp[2] + yp[3]) : yp[1]; }
    else { v.triggerType = trig; }
    var at = map["action.type"] || "command";
    v.actionType = at;
    var cmd = map["action.command"] || "";
    if (at === "app" && /^app:/.test(cmd)) {
      var sp = cmd.split(":");
      v.appOp = sp[1] || "package";
      v.appTarget = sp[2] || "";
    } else {
      v.command = cmd;
    }
    v.healthType = map["health.type"] || "none";
    v.healthTarget = map["health.target"] || "";
    v.recoveryType = map["recovery.type"] || "none";
    v.recoveryScript = map["recovery.script"] || "";
    v.retryMax = map["retry.max"] || "0";
    v.retryInterval = map["retry.interval"] || "60";
    v.retryCooldown = map["retry.cooldown"] || "0";
    v.timeout = map["advanced.timeout"] || "0";
    v.environment = map["advanced.environment"] || "";
    v.concurrency = map["advanced.concurrency"] || "0";
    v.logging = map["advanced.logging"] || "0";
    return v;
  }

  function formToTrigger(v) {
    var t = v.triggerType;
    switch (t) {
      case "boot": return "boot";
      case "time": return v.time;
      case "weekly": return "weekly:" + (v.weeklyDOW || "1") + ":" + (v.weeklyTime || "0000");
      case "nweekly": return "nweekly:" + (v.nweeklyN || "1") + ":" + (v.weeklyDOW || "1") + ":" + (v.weeklyTime || "0000");
      case "monthly": return "monthly:" + (v.monthlyDay || "1") + ":" + (v.monthlyTime || "0000");
      case "nmonthly": return "nmonthly:" + (v.nmonthlyN || "1") + ":" + (v.nmonthlyDay || "1") + ":" + (v.nmonthlyTime || "0000");
      case "yearly": return "yearly:" + (v.yearlyTime || "01010000").replace(/^([0-9]{2})([0-9]{2})([0-9]{4})$/, "$1:$2:$3");
      default: return t;
    }
  }

  function formToContent(v) {
    var cmd;
    if (v.actionType === "app") {
      cmd = "app:" + (v.appOp || "package") + ":" + (v.appTarget || "");
    } else {
      cmd = v.command || "";
    }
    var lines = [
      "schema_version=2",
      "id=" + v.id,
      "name=" + v.name,
      "enabled=" + (v.enabled === "0" ? "0" : "1"),
      "description=" + (v.description || ""),
      "trigger=" + formToTrigger(v),
      "action.type=" + v.actionType,
      "action.command=" + cmd,
      "action.notify_start=0",
      "action.notify_end=0",
      "action.delete=0",
      "action.termux=0",
      "action.interactive=0",
      "action.run_once_now=0",
      "action.boot=0",
      "action.msg=",
      "health.type=" + (v.healthType || "none"),
      "health.target=" + (v.healthTarget || ""),
      "recovery.type=" + (v.recoveryType || "none"),
      "recovery.script=" + (v.recoveryScript || ""),
      "retry.max=" + (v.retryMax || "0"),
      "retry.interval=" + (v.retryInterval || "60"),
      "retry.cooldown=" + (v.retryCooldown || "0"),
      "advanced.timeout=" + (v.timeout || "0"),
      "advanced.environment=" + (v.environment || ""),
      "advanced.concurrency=" + (v.concurrency || "0"),
      "advanced.logging=" + (v.logging || "0")
    ];
    return lines.join("\n");
  }

  function validateForm(v) {
    var errs = [];
    if (isUnimpl(v.triggerType)) { errs.push("Trigger " + v.triggerType + " 未实现（P3 暂不可用）"); }
    if (!v.id || !/^[A-Za-z0-9_.-]+$/.test(v.id) || /(\.\.)|\//.test(v.id)) { errs.push("ID 非法（仅 [A-Za-z0-9_.-]，禁路径穿越）"); }
    if (!v.name) { errs.push("Name 必填"); }
    if (v.actionType === "app" && !v.appTarget) { errs.push("App Target 必填"); }
    if (v.actionType !== "app" && !v.command) { errs.push("Command 必填"); }
    if (v.recoveryType === "script" && v.recoveryScript.charAt(0) !== "/") { errs.push("Recovery Script 必须为绝对路径"); }
    Object.keys(TASK_FORM_SCHEMA.fields).forEach(function (k) {
      var f = TASK_FORM_SCHEMA.fields[k];
      if (!f.pattern) { return; }
      var val = String(v[k] || "");
      if (val === "") { return; }
      if (f.pattern && !new RegExp(f.pattern).test(val)) { errs.push(f.label + " 格式非法"); }
      if (f.min !== undefined && f.max !== undefined) {
        var n = parseInt(val, 10);
        if (!isNaN(n) && (n < f.min || n > f.max)) { errs.push(f.label + " 超出范围 [" + f.min + "," + f.max + "]"); }
      }
    });
    return errs;
  }

  var editorState = { step: 0, editing: "", form: {} };

  function renderEditor(params) {
    var view = document.getElementById("view");
    view.textContent = "";
    var isEdit = params.id && params.id !== "new";
    var h = el("h2", { text: isEdit ? "Task Editor — " + escText(params.id) : "Task Editor — 新建任务" });
    view.appendChild(h);

    var errBox = el("div", { class: "banner offline", text: "" });
    errBox.style.display = "none";
    view.appendChild(errBox);
    var infoBox = el("div", { class: "banner online", text: "" });
    infoBox.style.display = "none";
    view.appendChild(infoBox);

    var stepsBar = el("div", { class: "editor-steps" });
    view.appendChild(stepsBar);

    var formWrap = el("div", { class: "editor-form" });
    view.appendChild(formWrap);

    var preview = el("pre", { class: "log mono editor-preview" });
    preview.style.display = "none";
    view.appendChild(preview);

    var btns = el("div", { class: "editor-btns" });
    var btnPrev = el("button", { text: "上一步" });
    var btnNext = el("button", { text: "下一步" });
    var btnPreview = el("button", { text: "校验预览" });
    var btnSave = el("button", { text: "保存" });
    var btnCancel = el("button", { text: "取消" });
    btns.appendChild(btnPrev); btns.appendChild(btnNext);
    btns.appendChild(btnPreview); btns.appendChild(btnSave); btns.appendChild(btnCancel);
    view.appendChild(btns);

    function showStep(idx) {
      editorState.step = idx;
      renderStep();
    }
    function renderStep() {
      stepsBar.textContent = "";
      TASK_FORM_SCHEMA.steps.forEach(function (s, i) {
        var a = el("a", { href: "#", class: "editor-step" + (i === editorState.step ? " active" : ""), text: s });
        a.addEventListener("click", function (e) { e.preventDefault(); showStep(i); });
        stepsBar.appendChild(a);
      });
      formWrap.textContent = "";
      var step = TASK_FORM_SCHEMA.steps[editorState.step];
      var fieldset = el("fieldset", {});
      fieldset.appendChild(el("legend", { text: step }));
      var errs = validateForm(editorState.form);
      if (errs.length) {
        errBox.style.display = "block";
        errBox.textContent = "前端校验：\n" + errs.join("\n");
      } else {
        errBox.style.display = "none";
      }
      Object.keys(TASK_FORM_SCHEMA.fields).forEach(function (k) {
        var f = TASK_FORM_SCHEMA.fields[k];
        if (f.step !== step) { return; }
        var row = el("div", { class: "editor-row" });
        var lbl = el("label", { text: f.label + (f.required ? " *" : "") });
        row.appendChild(lbl);
        if (f.type === "select") {
          var sel = el("select", {});
          f.options.forEach(function (o) {
            var opt = el("option", { value: o[0], text: o[1] });
            if (f.unimplemented && f.unimplemented.indexOf(o[0]) >= 0) {
              opt.setAttribute("disabled", "disabled");
              opt.textContent = o[1] + " — 未实现";
            }
            sel.appendChild(opt);
          });
          sel.value = editorState.form[k] || f.def || "";
          sel.addEventListener("change", function () {
            editorState.form[k] = sel.value;
            if (k === "actionType") {
              if (sel.value === "app" && editorState.form.command && !editorState.form.appTarget) {
                editorState.form.appTarget = "";
              }
            }
            renderStep();
          });
          row.appendChild(sel);
        } else if (f.type === "checkbox") {
          var chk = el("input", { type: "checkbox" });
          chk.checked = (editorState.form[k] === "1" || editorState.form[k] === undefined ? true : editorState.form[k] === "1");
          chk.addEventListener("change", function () {
            editorState.form[k] = chk.checked ? "1" : "0";
          });
          row.appendChild(chk);
        } else if (f.type === "textarea") {
          var ta = el("textarea", { rows: "3" });
          ta.value = editorState.form[k] || "";
          ta.addEventListener("input", function () { editorState.form[k] = ta.value; });
          row.appendChild(ta);
        } else {
          var inp = el("input", { type: "text", placeholder: f.placeholder || "" });
          inp.value = editorState.form[k] || "";
          inp.addEventListener("input", function () { editorState.form[k] = inp.value; });
          row.appendChild(inp);
        }
        formWrap.appendChild(row);
      });
      btnPrev.disabled = editorState.step === 0;
      btnNext.disabled = editorState.step >= TASK_FORM_SCHEMA.steps.length - 1;
    }

    btnPrev.addEventListener("click", function () { if (editorState.step > 0) { showStep(editorState.step - 1); } });
    btnNext.addEventListener("click", function () {
      if (editorState.step < TASK_FORM_SCHEMA.steps.length - 1) { showStep(editorState.step + 1); }
    });
    btnPreview.addEventListener("click", function () {
      var errs = validateForm(editorState.form);
      if (errs.length) {
        infoBox.style.display = "block";
        infoBox.textContent = "前端校验失败：\n" + errs.join("\n");
        infoBox.className = "banner offline";
        preview.style.display = "none";
        return;
      }
      var content = formToContent(editorState.form);
      preview.textContent = content;
      preview.style.display = "block";
      write("VALIDATE_TASK", { payload: b64encode(content) }).then(function (res) {
        infoBox.style.display = "block";
        if (res.ok) {
          infoBox.textContent = "后端校验通过 ✓";
          infoBox.className = "banner online";
        } else {
          infoBox.textContent = "后端校验失败：rc=" + (res.rc === undefined ? "?" : res.rc) + " " + escText(res.error || "");
          infoBox.className = "banner offline";
        }
      });
    });
    btnSave.addEventListener("click", function () {
      var errs = validateForm(editorState.form);
      if (errs.length) {
        infoBox.style.display = "block";
        infoBox.textContent = "前端校验失败，未保存：\n" + errs.join("\n");
        infoBox.className = "banner offline";
        return;
      }
      var content = formToContent(editorState.form);
      infoBox.style.display = "block";
      infoBox.textContent = "保存中…";
      infoBox.className = "banner online";
      write("EDIT_TASK", { id: b64encode(editorState.form.id), payload: b64encode(content) }).then(function (res) {
        if (res.ok) {
          infoBox.textContent = "已保存 ✓（旧配置保持原子，失败时自动回滚）";
          infoBox.className = "banner online";
        } else {
          infoBox.textContent = "保存失败（旧配置未变）：rc=" + (res.rc === undefined ? "?" : res.rc) + " " + escText(res.error || "");
          infoBox.className = "banner offline";
        }
      });
    });
    btnCancel.addEventListener("click", function () {
      editorState.form = {};
      window.location.hash = "#tasks";
    });

    // 加载既有任务（GET_TASK_EDIT → base64 解码 → 表单）
    if (isEdit) {
      write("GET_TASK_EDIT", { id: b64encode(params.id) }).then(function (res) {
        if (!res.ok || res.payload === undefined) {
          errBox.style.display = "block";
          errBox.textContent = "读取任务失败：" + escText((res && res.error) || "task_not_found");
          return;
        }
        var content = b64decode(res.payload);
        editorState.form = taskContentToForm(parseTaskContent(content));
        editorState.editing = params.id;
        renderStep();
      });
    } else {
      editorState.form = { triggerType: "time", actionType: "command", enabled: "1", retryMax: "0", retryInterval: "60", retryCooldown: "0", timeout: "0", concurrency: "0", logging: "0", healthType: "none", recoveryType: "none" };
      renderStep();
    }
  }
  /* ── 路由 ───────────────────────────────────────────────────────────── */
  function parseHash() {
    var hh = window.location.hash || "#dashboard";
    if (hh.indexOf("#task/") === 0) { return { view: "task", id: decodeURIComponent(hh.slice(6)) }; }
    if (hh.indexOf("#editor/") === 0) { return { view: "editor", id: decodeURIComponent(hh.slice(8)) }; }
    if (hh === "#editor" || hh.indexOf("#editor") === 0) { return { view: "editor", id: "new" }; }
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
    } else if (r.view === "editor") {
      renderEditor({ id: r.id || "new" });
      read("GET_TASK_DETAIL", { id: r.id }).then(function (d) { setBadge(!!d.ok); renderTaskDetail(d, r.id); });
      read("GET_TASK_DETAIL", { id: r.id }).then(function (d) { setBadge(!!d.ok); renderTaskDetail(d, r.id); });
    } else {
      read("GET_SUMMARY", {}).then(function (d) { setBadge(!!d.ok); renderDashboard(d); });
    }
  }

  window.addEventListener("hashchange", route);
  document.addEventListener("DOMContentLoaded", route);
})();
