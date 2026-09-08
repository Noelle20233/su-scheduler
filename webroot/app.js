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

  /* ── 周期刷新 + 错误保留上次数据（P5-06）────────────────────────────── */
  var refreshTimer = null;
  var lastData = {};

  function lastUpdatedTime() {
    var d = new Date();
    function p(n) { return (n < 10 ? "0" : "") + n; }
    return p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds());
  }
  function updateIndicator(view, text) {
    var ind = document.getElementById("refresh-indicator");
    if (!ind) {
      ind = el("p", { id: "refresh-indicator", class: "refresh-indicator", text: "" });
      view.insertBefore(ind, view.firstChild);
    }
    ind.textContent = text;
  }
  function showErrBanner(view, info) {
    var b = document.getElementById("err-banner");
    if (!b) {
      b = el("div", { id: "err-banner", class: "err-banner" });
      view.insertBefore(b, view.firstChild);
    }
    b.textContent = info;
  }
  function clearErrBanner() {
    var b = document.getElementById("err-banner");
    if (b && b.parentNode) { b.parentNode.removeChild(b); }
  }
  function stopRefresh() {
    if (refreshTimer !== null) {
      clearInterval(refreshTimer);
      refreshTimer = null;
    }
  }
  function startRefresh(fn, intervalMs) {
    stopRefresh();
    refreshTimer = setInterval(fn, intervalMs);
  }
  function errInfo(data) {
    var e = data && data.error;
    return "刷新失败（上次数据已过期）：" + escText(e || "") +
      " (rc=" + ((data && data.rc === undefined) ? "?" : (data && data.rc)) + ")";
  }
  function markRefreshErr(view, viewName, data) {
    if (!lastData[viewName]) {
      view.textContent = "";
      view.appendChild(offlineBanner());
    }
    showErrBanner(view, errInfo(data));
    updateIndicator(view, "上次更新 " + lastUpdatedTime() + " — 刷新失败（上次数据已过期）");
  }
  function loadAndRender(op, params, renderFn) {
    read(op, params).then(renderFn).catch(function (e) {
      renderFn({ ok: false, error: String((e && e.message) || e || "read_failed"), rc: -1 });
    });
  }
  function parseTs(s) {
    var m = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})$/.exec(String(s || ""));
    if (!m) { return NaN; }
    return Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]);
  }
  function lastDuration(t) {
    if (!t || !t.last_start || !t.last_end) { return null; }
    var ms = parseTs(t.last_end) - parseTs(t.last_start);
    if (isNaN(ms) || ms < 0) { return null; }
    return Math.floor(ms / 1000);
  }

  /* ── P5-07 依赖可视化 + 批量操作 ─────────────────────────────────────── */
  function depEntries(depStr) {
    return String(depStr || "").split(/[, ]+/).filter(function (s) { return s; });
  }
  function depBadges(depStr) {
    var wrap = el("span", { class: "deps" });
    depEntries(depStr).forEach(function (e) {
      var b = el("span", { class: "dep-badge" + (e.charAt(0) === "?" ? " optional" : "") });
      b.textContent = e;
      wrap.appendChild(b);
    });
    return wrap;
  }
  function depCell(t) {
    var td = el("td", { class: "deps-cell" });
    var deps = depEntries(t.dependency);
    td.appendChild(deps.length ? depBadges(t.dependency) : el("span", { class: "dep-none", text: "-" }));
    return td;
  }
  function selectedIds() {
    var ids = [];
    document.querySelectorAll(".batch-cb:checked").forEach(function (cb) {
      ids.push(cb.getAttribute("data-id"));
    });
    return ids;
  }
  function renderBatchResults(box, op, results) {
    box.textContent = "";
    box.appendChild(el("p", { class: "batch-title", text: op + " 批量结果：" }));
    var fails = 0;
    results.forEach(function (r) {
      if (!r.ok) { fails++; }
      var line = el("div", { class: "batch-item" + (r.ok ? " ok" : " fail") });
      line.textContent = (r.ok ? "OK  " : "FAILED  ") + r.id + "  rc=" + r.rc + (r.error ? "  " + r.error : "");
      box.appendChild(line);
    });
    box.appendChild(el("p", { class: "batch-sum" + (fails ? " fail" : " ok"),
      text: "成功 " + (results.length - fails) + " / " + results.length + (fails ? "，失败 " + fails : "（全部成功）") }));
  }
  function runBatch(op, label, box) {
    var ids = selectedIds();
    if (!ids.length) { box.textContent = "未选中任务"; return; }
    runBatchIds(op, label, ids, box);
  }
  function runBatchIds(op, label, ids, box) {
    box.textContent = "";
    var pending = ids.length;
    var results = [];
    ids.forEach(function (id) {
      write(op, { id: id }).then(function (res) {
        results.push({ id: id, rc: (res && res.rc === undefined) ? "?" : (res && res.rc), error: (res && res.error) || "", ok: !!(res && res.ok) });
        pending--;
        if (pending === 0) { renderBatchResults(box, op, results); }
      });
    });
  }
  function batchBar() {
    var bar = el("div", { class: "batchbar" });
    var cbAll = el("input", { type: "checkbox", class: "batch-all", title: "全选" });
    cbAll.addEventListener("change", function () {
      document.querySelectorAll(".batch-cb").forEach(function (cb) { cb.checked = cbAll.checked; });
    });
    bar.appendChild(cbAll);
    bar.appendChild(el("span", { class: "batch-hint", text: "全选" }));
    var box = el("div", { class: "batch-results" });
    [["Start", "START_TASK"], ["Stop", "STOP_TASK"], ["Restart", "RESTART_TASK"],
     ["Check", "CHECK_TASK"], ["Enable", "ENABLE_TASK"], ["Disable", "DISABLE_TASK"]].forEach(function (pair) {
      var b = el("button", { class: "batch-btn", text: pair[0], "data-op": pair[1] });
      b.addEventListener("click", function () { runBatch(pair[1], pair[0], box); });
      bar.appendChild(b);
    });
    bar.appendChild(box);
    return bar;
  }
  function renderDepView(data) {
    var block = el("div", { class: "depview" });
    block.appendChild(el("h2", { text: "依赖关系" }));
    block.appendChild(el("a", { class: "dag-jump", href: "#dag", text: "运行态请见 DAG 链视图 →" }));
    var errs = data.dep_errors || [];
    var errBox = el("div", { class: "dep-errors" });
    if (errs.length) {
      errBox.className = "dep-errors has-errors";
      errBox.appendChild(el("p", { class: "dep-errors-title", text: "依赖图错误（环 / 无效依赖）：" }));
      errs.forEach(function (e) { errBox.appendChild(el("div", { class: "dep-error", text: e })); });
    } else {
      errBox.appendChild(el("p", { class: "dep-errors-ok", text: "依赖图无环 / 无无效依赖错误。" }));
    }
    block.appendChild(errBox);
    var fwd = el("div", { class: "dep-col" });
    fwd.appendChild(el("h3", { text: "正向依赖（任务 → 依赖）" }));
    var rev = el("div", { class: "dep-col" });
    rev.appendChild(el("h3", { text: "反向依赖（谁依赖我）" }));
    var revMap = {};
    (data.tasks || []).forEach(function (t) {
      depEntries(t.dependency).forEach(function (e) {
        var target = e;
        if (target.charAt(0) === "?") { target = target.slice(1); }
        if (target.indexOf(":") >= 0) { target = target.slice(0, target.indexOf(":")); }
        revMap[target] = revMap[target] || [];
        revMap[target].push(t.id);
      });
    });
    (data.tasks || []).forEach(function (t) {
      var row = el("div", { class: "dep-row" });
      row.appendChild(el("span", { class: "dep-from", text: t.id }));
      var deps = depEntries(t.dependency);
      row.appendChild(deps.length ? depBadges(t.dependency) : el("span", { class: "dep-none", text: "（无依赖）" }));
      fwd.appendChild(row);
    });
    var revKeys = Object.keys(revMap);
    if (!revKeys.length) {
      rev.appendChild(el("p", { class: "dep-none", text: "（无任务依赖本任务）" }));
    } else {
      revKeys.forEach(function (k) {
        var row = el("div", { class: "dep-row" });
        row.appendChild(el("span", { class: "dep-from", text: k }));
        row.appendChild(el("span", { class: "dep-revlist", text: revMap[k].join(", ") }));
        rev.appendChild(row);
      });
    }
    var cols = el("div", { class: "dep-cols" });
    cols.appendChild(fwd); cols.appendChild(rev);
    block.appendChild(cols);
    return block;
  }

  /* ── P6-08 DAG 链视图（D58 只增键 dag.chains/runs；账本态 + 现图边）────── */
  function dagNodeBadge(node) {
    var st = String((node && node.state) || "");
    var note = String((node && node.note) || "");
    var m = [["STOPPED", "已完成", "dag-n-done"],
             ["FAILED", "失败", "dag-n-fail"],
             ["RUNNING", "运行中", "dag-n-run"],
             ["STARTING", "运行中", "dag-n-run"]];
    var i;
    if (st === "FAILED" && note.indexOf("gate-fail") >= 0) { return ["失败·传播", "dag-n-fail"]; }
    if (st === "FAILED" && note.indexOf("start-fail") >= 0) { return ["失败·启动失败", "dag-n-fail"]; }
    if (st === "PENDING") {
      if (note.indexOf("disabled") >= 0) { return ["中断路", "dag-n-int"]; }
      if (note.indexOf("cond-unmet") >= 0) { return ["等待·条件", "dag-n-wait"]; }
      if (note.indexOf("defer") >= 0) { return ["顺延·并行", "dag-n-wait"]; }
      if (note.indexOf("waiting") >= 0) { return ["等待", "dag-n-wait"]; }
      return ["待调度", "dag-n-wait"];
    }
    for (i = 0; i < m.length; i++) { if (st === m[i][0]) { return [m[i][1], m[i][2]]; } }
    if (st === "WAITING") { return ["等待·门控", "dag-n-wait"]; }
    if (st === "UNKNOWN" || st === "") { return ["未知", "dag-n-unknown"]; }
    return [st, "dag-n-run"];
  }
  function dagTaskMap(tasks) {
    var map = {};
    (tasks || []).forEach(function (t) { map[t.id] = t; });
    return map;
  }
  /* 现图链拓扑（前端由 tasks[].dependency 聚合——与 P5-07 dep 视图同一数据源，
     不新增 IPC op；闭包 = 非 chain 触发根 → trigger=chain 后代）。 */
  function dagChainTopology(tasks) {
    var byId = dagTaskMap(tasks);
    var edges = {};        // up → [{down, entry}]
    (tasks || []).forEach(function (t) {
      depEntries(t.dependency).forEach(function (e) {
        var up = e;
        if (up.charAt(0) === "?") { up = up.slice(1); }
        if (up.indexOf(":") >= 0) { up = up.slice(0, up.indexOf(":")); }
        if (!edges[up]) { edges[up] = []; }
        edges[up].push({ down: t.id, entry: e });
      });
    });
    var chains = {};       // root → { nodes:[ids], edges:[{up,down,entry}] }
    function walk(rootId, acc, seen) {
      var list = edges[rootId] || [];
      list.forEach(function (ed) {
        var down = ed.down;
        if (!byId[down] || byId[down].trigger !== "chain") { return; }
        acc.edges.push({ up: rootId, down: down, entry: ed.entry });
        if (!seen[down]) {
          seen[down] = true; acc.nodes.push(down);
          walk(down, acc, seen);
        }
      });
    }
    (tasks || []).forEach(function (t) {
      if (t.trigger === "chain") { return; }
      if (!edges[t.id]) { return; }
      var acc = { nodes: [t.id], edges: [] };
      walk(t.id, acc, {});
      if (acc.edges.length) { chains[t.id] = acc; }
    });
    return chains;
  }
  function dagProgressBar(done, total) {
    var wrap = el("div", { class: "dag-prog" });
    var d = Number(done) || 0; var t = Number(total) || 0;
    var pct = t > 0 ? Math.min(100, Math.round(d * 100 / t)) : 0;
    var fill = el("div", { class: "dag-prog-fill" });
    fill.style.width = pct + "%";
    wrap.appendChild(fill);
    wrap.appendChild(el("span", { class: "dag-prog-text", text: d + "/" + t }));
    return wrap;
  }
  /* 链级「停止/重启」= 对链成员批量发起**节点级** op（D54：v1 无链级取消 API、
     零新 IPC op；B19 逐任务结果，复用 P5-07 runBatchIds/write 通道）。 */
  function dagChainCtlBar(rootId, memberIds) {
    var bar = el("div", { class: "dag-ctlbar" });
    bar.appendChild(el("span", { class: "dag-ctl-note",
      text: "整链操作 = 批量节点操作（对链成员逐个发起节点级 op，逐任务返回结果；v1 无链级取消 API）" }));
    var box = el("div", { class: "batch-results" });
    [["停止链", "STOP_TASK"], ["重启链", "RESTART_TASK"], ["启用链", "ENABLE_TASK"], ["禁用链", "DISABLE_TASK"]].forEach(function (pair) {
      var b = el("button", { class: "batch-btn dag-batch-btn", text: pair[0] + "（批量节点操作）", "data-op": pair[1] });
      b.addEventListener("click", function () { runBatchIds(pair[1], pair[0], memberIds.slice(), box); });
      bar.appendChild(b);
    });
    bar.appendChild(box);
    return bar;
  }
  function dagNodeRow(node, taskMap, ledgerState) {
    var tr = el("tr");
    var badge = dagNodeBadge(node);
    var a = el("a", { href: "#task/" + encodeURIComponent(node.id), text: escText(node.id) });
    var tdId = el("td"); tdId.appendChild(a); tr.appendChild(tdId);
    tr.appendChild(el("td", { class: "dag-role", text: node.role === "root" ? "根" : "节点" }));
    tr.appendChild(el("td", { class: "dag-badge " + badge[1], text: badge[0] }));
    tr.appendChild(el("td", { class: "dag-state", text: escText(node.state) }));
    var reason = node.note || "";
    if (String(node.note || "").indexOf("gate-fail") >= 0) {
      var ups = [];
      depEntries((taskMap[node.id] || {}).dependency).forEach(function (e) {
        var up = e; if (up.charAt(0) === "?") { up = up.slice(1); }
        if (up.indexOf(":") >= 0) { up = up.slice(0, up.indexOf(":")); }
        if (ledgerState[up] === "FAILED") { ups.push(up); }
      });
      if (ups.length) { reason = reason + " ← dep-fail: " + ups.join(", "); }
    }
    tr.appendChild(el("td", { class: "dag-note", text: reason }));
    var depTd = el("td", { class: "deps-cell" });
    depTd.appendChild(depEntries((taskMap[node.id] || {}).dependency).length
      ? depBadges((taskMap[node.id] || {}).dependency)
      : el("span", { class: "dep-none", text: node.role === "root" ? "（链根）" : "-" }));
    tr.appendChild(depTd);
    return tr;
  }
  function dagLedgerStates(chain) {
    var s = {};
    (chain.nodes || []).forEach(function (n) { s[n.id] = n.state; });
    return s;
  }
  function renderDagChainBlock(chain, taskMap) {
    var block = el("div", { class: "dag-chain" });
    var head = el("div", { class: "dag-head" });
    var rootLink = el("a", { href: "#task/" + encodeURIComponent(chain.root), text: "链 " + escText(chain.root) });
    head.appendChild(rootLink);
    head.appendChild(el("span", { class: "dag-run", text: "run " + escText(chain.run) }));
    head.appendChild(el("span", { class: "dag-runstate rs-" + escText(chain.run_state), text: escText(chain.run_state) }));
    head.appendChild(dagProgressBar(chain.done, chain.total));
    block.appendChild(head);
    if ((chain.frontier || []).length) {
      block.appendChild(el("p", { class: "dag-frontier", text: "在途节点：" + chain.frontier.join(", ") }));
    }
    var ledger = dagLedgerStates(chain);
    var table = el("table", { class: "tbl dag-table" });
    var thead = el("tr");
    ["节点", "角色", "状态", "账本态", "note / 失败原因", "入边（Required/Optional/:STATE）"].forEach(function (h) {
      thead.appendChild(el("th", { text: h }));
    });
    table.appendChild(thead);
    var ids = [];
    (chain.nodes || []).forEach(function (n) {
      ids.push(n.id);
      table.appendChild(dagNodeRow(n, taskMap, ledger));
    });
    block.appendChild(table);
    block.appendChild(dagChainCtlBar(chain.root, ids));
    return block;
  }
  function renderDagChainStatic(rootId, topo, taskMap) {
    var block = el("div", { class: "dag-chain dag-chain-static" });
    var head = el("div", { class: "dag-head" });
    head.appendChild(el("a", { href: "#task/" + encodeURIComponent(rootId), text: "链 " + escText(rootId) }));
    head.appendChild(el("span", { class: "dag-runstate rs-NOTRUN", text: "尚未触发（静态拓扑）" }));
    block.appendChild(head);
    var table = el("table", { class: "tbl dag-table" });
    var thead = el("tr");
    ["节点", "边"].forEach(function (h) { thead.appendChild(el("th", { text: h })); });
    table.appendChild(thead);
    (topo.nodes || []).forEach(function (id) {
      var tr = el("tr");
      var a = el("a", { href: "#task/" + encodeURIComponent(id), text: escText(id) });
      var td = el("td"); td.appendChild(a); tr.appendChild(td);
      var ins = (topo.edges || []).filter(function (e) { return e.down === id; })
        .map(function (e) { return e.up + "→" + e.down; });
      var cell = el("td");
      cell.appendChild(ins.length ? depBadges(ins.map(function (s) { return s.split("→")[0]; }).join(",")) : el("span", { class: "dep-none", text: "（根）" }));
      tr.appendChild(cell);
      table.appendChild(tr);
    });
    block.appendChild(table);
    return block;
  }
  function renderDagView(data) {
    var view = document.getElementById("view");
    if (!data.ok) { markRefreshErr(view, "dag", data); return; }
    lastData.dag = data;
    clearErrBanner();
    view.textContent = "";
    updateIndicator(view, "上次更新 " + lastUpdatedTime());
    view.appendChild(el("h2", { text: "DAG 链视图" }));
    var dag = data.dag || {};
    var sum = el("div", { class: "dag-summary" });
    sum.appendChild(el("span", { class: "dag-chip", text: "活跃链 run：" + escText(dag.active === undefined ? 0 : dag.active) + " / " + escText(dag.limit === undefined ? 0 : dag.limit) }));
    sum.appendChild(el("span", { class: "dag-chip" + ((Number(dag.recent_failed) || 0) > 0 ? " bad" : ""), text: "保留史内失败 run：" + escText(dag.recent_failed === undefined ? 0 : dag.recent_failed) }));
    view.appendChild(sum);
    var taskMap = dagTaskMap(data.tasks);
    var topo = dagChainTopology(data.tasks || []);
    var chains = dag.chains || [];
    var liveRoots = {};
    chains.forEach(function (c) {
      liveRoots[c.root] = true;
      view.appendChild(renderDagChainBlock(c, taskMap));
    });
    Object.keys(topo).forEach(function (r) {
      if (!liveRoots[r]) { view.appendChild(renderDagChainStatic(r, topo[r], taskMap)); }
    });
    /* 链路审计记录（dag.audit 只增键：op=dag 审计尾读，既有 GET_SUMMARY 通道） */
    var aud = dag.audit || [];
    if (aud.length) {
      var audBox = el("div", { class: "dag-audit" });
      audBox.appendChild(el("h3", { text: "链路审计记录（op=dag，最近 " + aud.length + " 条）" }));
      aud.forEach(function (l) { audBox.appendChild(el("div", { class: "dag-audit-row", text: escText(l) })); });
      view.appendChild(audBox);
    }
    if (!chains.length && !Object.keys(topo).length) {
      view.appendChild(el("p", { class: "empty", text: "（暂无链：trigger=chain 节点或其 run 账本不存在）" }));
    }
  }

  /* ── 视图：Dashboard ────────────────────────────────────────────────── */
  function renderDashboard(data) {
    var view = document.getElementById("view");
    if (!data.ok) { markRefreshErr(view, "dashboard", data); return; }
    lastData.dashboard = data;
    clearErrBanner();
    view.textContent = "";
    updateIndicator(view, "上次更新 " + lastUpdatedTime());
    var counts = data.counts || {};
    var grid = el("div", { class: "cards" });
    grid.appendChild(card("Total Tasks", counts.total || 0, "c-total"));
    grid.appendChild(card("Running", counts.running || 0, "c-running"));
    grid.appendChild(card("Healthy", counts.healthy || 0, "c-healthy"));
    grid.appendChild(card("Failed", counts.failed || 0, "c-failed"));
    grid.appendChild(card("Disabled", counts.disabled || 0, "c-disabled"));
    grid.appendChild(card("Waiting", counts.waiting || 0, "c-waiting"));
    grid.appendChild(card("Unhealthy", counts.unhealthy || 0, "c-unhealthy"));
    grid.appendChild(card("Recovering", counts.recovering || 0, "c-recovering"));
    view.appendChild(grid);

    var mode = el("p", { class: "mode", text: "配置模式：" + escText(data.mode || "legacy") });
    view.appendChild(mode);

    var h = el("h2", { text: "Tasks" });
    view.appendChild(h);
    view.appendChild(batchBar());
    var list = el("table", { class: "tbl" });
    var thead = el("tr");
    ["", "ID", "名称", "状态", "Trigger", "Action", "Health", "最近运行", "重启次数", "依赖"].forEach(function (t) {
      thead.appendChild(el("th", { text: t }));
    });
    list.appendChild(thead);
    (data.tasks || []).forEach(function (t) {
      var tr = el("tr");
      var cb = el("input", { type: "checkbox", class: "batch-cb", "data-id": t.id });
      var tdSel = el("td"); tdSel.appendChild(cb); tr.appendChild(tdSel);
      var a = el("a", { href: "#task/" + encodeURIComponent(t.id), text: escText(t.id) });
      var td0 = el("td"); td0.appendChild(a); tr.appendChild(td0);
      tr.appendChild(el("td", { text: escText(t.name) }));
      tr.appendChild(el("td", { class: "st st-" + escText(t.status), text: escText(t.status) }));
      tr.appendChild(el("td", { text: escText(t.trigger) }));
      tr.appendChild(el("td", { class: "mono", text: escText(t.action) }));
      tr.appendChild(el("td", { text: escText(t.health) }));
      tr.appendChild(el("td", { text: escText(t.last_run) }));
      tr.appendChild(el("td", { text: escText(t.restart_count) }));
      tr.appendChild(depCell(t));
      list.appendChild(tr);
    });
    view.appendChild(list);
    if (!(data.tasks || []).length) {
      view.appendChild(el("p", { class: "empty", text: "（空：暂无任务）" }));
    }
    view.appendChild(renderDepView(data));
  }

  /* ── 视图：Task List ────────────────────────────────────────────────── */
  function renderTasks(data) {
    var view = document.getElementById("view");
    if (!data.ok) { markRefreshErr(view, "tasks", data); return; }
    lastData.tasks = data;
    clearErrBanner();
    view.textContent = "";
    updateIndicator(view, "上次更新 " + lastUpdatedTime());
    var h = el("h2", { text: "Task List" });
    view.appendChild(h);
    view.appendChild(batchBar());
    var list = el("table", { class: "tbl" });
    var thead = el("tr");
    ["", "ID", "名称", "状态", "Trigger", "Action", "Health", "最近运行", "重启次数", "启用", "依赖"].forEach(function (t) {
      thead.appendChild(el("th", { text: t }));
    });
    list.appendChild(thead);
    (data.tasks || []).forEach(function (t) {
      var tr = el("tr");
      var cb = el("input", { type: "checkbox", class: "batch-cb", "data-id": t.id });
      var tdSel = el("td"); tdSel.appendChild(cb); tr.appendChild(tdSel);
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
      tr.appendChild(depCell(t));
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
    if (!data.ok) {
      if (data.error === "task_not_found" && !lastData.task) {
        view.textContent = "";
        view.appendChild(el("p", { class: "empty", text: "任务不存在或配置无效：" + escText(id) }));
        showErrBanner(view, "刷新失败（上次数据已过期）：" + escText(id) + " (rc=3)");
        updateIndicator(view, "上次更新 " + lastUpdatedTime() + " — 刷新失败（上次数据已过期）");
        return;
      }
      markRefreshErr(view, "task", data);
      return;
    }
    lastData.task = data;
    clearErrBanner();
    view.textContent = "";
    updateIndicator(view, "上次更新 " + lastUpdatedTime());
    var t = data.task || {};
    var h = el("h2", { text: "Task Detail — " + escText(t.id) });
    view.appendChild(h);
    var grid = el("div", { class: "cards" });
    grid.appendChild(card("状态", t.status, "st-" + escText(t.status)));
    grid.appendChild(card("Trigger", t.trigger));
    grid.appendChild(card("Enabled", t.enabled));
    grid.appendChild(card("PID", t.pid));
    grid.appendChild(card("上次退出码", t.last_exit));
    grid.appendChild(card("上次启动", t.last_start));
    grid.appendChild(card("上次结束", t.last_end));
    grid.appendChild(card("重启次数", t.restart_count));
    grid.appendChild(card("运行次数", t.run_count));
    var dur = lastDuration(t);
    if (dur !== null) { grid.appendChild(card("last_duration", dur + "s")); }
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
    kv("dependency", t.dependency);
    kv("condition", t.condition);
    kv("dependency_state", t.dependency_state);
    kv("gate_state", t.gate_state);
    kv("condition_state", t.condition_state);
    kv("last_event", t.last_event);
    view.appendChild(info);

    /* P6-08（D58）：链可观测块（dag 只增键；旧 daemon 无该键 → 整块隐藏） */
    var dg = t.dag;
    if (dg && dg.role) {
      var dagInfo = el("dl", { class: "kv" });
      function dkv(k, v) {
        dagInfo.appendChild(el("dt", { text: k }));
        dagInfo.appendChild(el("dd", { class: "mono", text: escText(v) }));
      }
      dkv("dag.chain_root", dg.chain_root);
      dkv("dag.role", dg.role === "root" ? "root（链根）" : dg.role === "node" ? "node（链节点）" : dg.role);
      dkv("dag.run", dg.run);
      dkv("dag.run_state", dg.run_state);
      dkv("dag.node_state", dg.node_state);
      dkv("dag.note", dg.note);
      if (dg.reason) { dkv("dag.reason", dg.reason); }
      view.appendChild(dagInfo);
      var hist = dg.runs || [];
      if (hist.length) {
        var histBox = el("div", { class: "dag-history" });
        histBox.appendChild(el("h3", { text: "链 run 历史（RUNS_KEEP 内，最新在前）" }));
        hist.forEach(function (h) {
          histBox.appendChild(el("div", { class: "dag-hist-row",
            text: "run " + escText(h.run) + " [" + escText(h.run_state) + "] 进度 " + escText(h.done) + "/" + escText(h.total) + " created=" + escText(h.created) }));
        });
        view.appendChild(histBox);
      }
      var dagLink = el("a", { class: "dag-jump", href: "#dag", text: "打开 DAG 链视图" });
      view.appendChild(dagLink);
    }

    /* 运行历史（events） */
    var evBtn = el("button", { text: "加载运行历史 (events)" });
    evBtn.addEventListener("click", function () {
      read("GET_TASK_EVENTS", { id: t.id, lines: "50" }).then(function (ev) {
        renderEvents(ev, t.id);
      });
    });
    view.appendChild(evBtn);

    /* 控制按钮（P3-07）：经 IPC 写操作桥（suWriter）→ daemon → §24 tctl_*；
       与 CLI task <op> <id> 共用同一控制 API。按钮只发起受控 IPC op，不执行
       任何 shell。 */
    var ctlBar = el("div", { class: "ctlbar" });
    function ctlBtn(label, op) {
      var b = el("button", { text: label, "data-op": op });
      b.addEventListener("click", function () {
        b.disabled = true;
        write(op, { id: t.id }).then(function (res) {
          b.disabled = false;
          var msg;
          if (res && res.ok) { msg = op + " 成功"; }
          else {
            var rc = (res && res.rc === undefined) ? "?" : (res && res.rc);
            msg = op + " 失败: rc=" + rc + " " + escText((res && res.error) || "");
          }
          var note = el("p", { class: "note", text: msg });
          view.appendChild(note);
        });
      });
      return b;
    }
    [["Start", "START_TASK"], ["Stop", "STOP_TASK"], ["Restart", "RESTART_TASK"],
     ["Check", "CHECK_TASK"], ["Enable", "ENABLE_TASK"], ["Disable", "DISABLE_TASK"]].forEach(function (pair) {
      ctlBar.appendChild(ctlBtn(pair[0], pair[1]));
    });
    var logsBtn = el("button", { text: "日志 (logs)" });
    logsBtn.addEventListener("click", function () {
      read("GET_TASK_LOG", { id: t.id, lines: "100" }).then(function (d) { renderLogBlock(d, "Task 日志 " + t.id); });
    });
    ctlBar.appendChild(logsBtn);
    view.appendChild(ctlBar);
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
    /* P6-08：链事件过滤（dag_register/dag_dispatch 令牌；纯展示过滤，数据仍来自
       既有 GET_TASK_EVENTS，无新 op） */
    var allLines = data.lines || [];
    pre.textContent = allLines.join("\n");
    var dagOnly = el("input", { type: "checkbox", class: "dag-events-filter" });
    dagOnly.addEventListener("change", function () {
      pre.textContent = (dagOnly.checked
        ? allLines.filter(function (l) { return l.indexOf("|dag_register|") >= 0 || l.indexOf("|dag_dispatch|") >= 0; })
        : allLines).join("\n");
    });
    var filterWrap = el("label", { class: "dag-filter-label" });
    filterWrap.appendChild(dagOnly);
    filterWrap.appendChild(el("span", { text: " 只看链事件（dag_register / dag_dispatch）" }));
    container.appendChild(filterWrap);
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
        read("GET_DAEMON_LOG", p).then(function (d) { renderLogBlock(d, "Daemon 日志", true); });
      }
    });
    form.appendChild(el("span", { text: "类型: " })); form.appendChild(typeSel);
    form.appendChild(el("span", { text: " 行数: " })); form.appendChild(sel);
    form.appendChild(el("span", { text: "  task id: " })); form.appendChild(idInput);
    form.appendChild(btn);
    view.appendChild(form);
    /* 默认加载 daemon 日志 */
    read("GET_DAEMON_LOG", { lines: "100" }).then(function (d) { renderLogBlock(d, "Daemon 日志", true); });
  }

  function renderLogBlock(data, title, allowDagFilter) {
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
    var allLines = data.lines || [];
    pre.textContent = allLines.join("\n");
    /* P6-08：审计入口过滤（op=dag 审计行走既有 GET_DAEMON_LOG 通道原样返回；
       过滤仅影响展示，零新 op） */
    if (allowDagFilter) {
      var dagOnly = el("input", { type: "checkbox", class: "dag-log-filter" });
      dagOnly.addEventListener("change", function () {
        pre.textContent = (dagOnly.checked
          ? allLines.filter(function (l) { return l.indexOf("op=dag|") >= 0; })
          : allLines).join("\n");
      });
      var filterWrap = el("label", { class: "dag-filter-label" });
      filterWrap.appendChild(dagOnly);
      filterWrap.appendChild(el("span", { text: " 只看链审计（op=dag）" }));
      block.appendChild(filterWrap);
    }
    block.appendChild(pre);
    view.appendChild(block);
  }

  /* ── Task Editor（P3-06）+ 控制按钮（P3-07）────────────────────────────────── */
  var WRITE_OPS = ["GET_TASK_EDIT", "VALIDATE_TASK", "EDIT_TASK", "DELETE_TASK",
                   "ENABLE_TASK", "DISABLE_TASK", "START_TASK", "STOP_TASK",
                   "RESTART_TASK", "CHECK_TASK"];

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
      logging:{ step: "Advanced", type: "text", label: "Logging lines (0-1000000)", def: "0", pattern: "^[0-9]+$", min: 0, max: 1000000 },
      dependency:{ step: "Advanced", type: "text", label: "Dependency ([?]<task-id>[:STATE], 逗号分隔)", placeholder: "?task_boot:STOPPED, task_daily", max: 512 },
      condition:{ step: "Advanced", type: "text", label: "Condition ({{ 谓词 }})", placeholder: "{{ time.hour == 8 }}", max: 512 }
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
    v.dependency = map.dependency || "";
    v.condition = map.condition || "";
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
      "advanced.logging=" + (v.logging || "0"),
      "dependency=" + (v.dependency || ""),
      "condition=" + (v.condition || "")
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
    if (v.dependency) {
      var depParts = String(v.dependency).split(/[, ]+/).filter(function (s) { return s; });
      if (!depParts.length) { errs.push("Dependency 格式非法（[?]<task-id>[:STATE]，逗号/空格分隔）"); }
      depParts.forEach(function (e) {
        var d = e;
        if (d.charAt(0) === "?") { d = d.slice(1); }
        if (d.indexOf(":") >= 0) { d = d.slice(0, d.indexOf(":")); }
        if (!/^[A-Za-z0-9_.-]+$/.test(d) || /(\.\.)|\//.test(d)) {
          errs.push("Dependency 含非法 task-id（仅 [A-Za-z0-9_.-]，禁路径穿越）：" + e);
        }
      });
    }
    if (v.condition) {
      var c = String(v.condition);
      if (/[\u0000-\u001f\u007f]/.test(c) || /[$`;]/.test(c) || /[|><]/.test(c)) {
        errs.push("Condition 含非法字符（仅可打印 ASCII，无 ; $ \u0060 | > < 注入）");
      } else if (c.indexOf("{{") !== 0 || c.indexOf("}}") < 2) {
        errs.push("Condition 应形如 {{ 谓词 }}（白名单谓词，如 {{ time.hour == 8 }}）");
      }
    }
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
    stopRefresh();
    document.querySelectorAll("#nav a").forEach(function (a) {
      a.classList.toggle("active", a.getAttribute("data-view") === r.view);
    });
    if (r.view === "tasks") {
      loadAndRender("GET_SUMMARY", {}, function (d) { setBadge(!!d.ok); renderTasks(d); });
      startRefresh(function () {
        loadAndRender("GET_SUMMARY", {}, function (d) { setBadge(!!d.ok); renderTasks(d); });
      }, 10000);
    } else if (r.view === "dag") {
      loadAndRender("GET_SUMMARY", {}, function (d) { setBadge(!!d.ok); renderDagView(d); });
      startRefresh(function () {
        loadAndRender("GET_SUMMARY", {}, function (d) { setBadge(!!d.ok); renderDagView(d); });
      }, 5000);
    } else if (r.view === "logs") {
      read("GET_DAEMON_LOG", { lines: "5" }).then(function (d) { setBadge(!!d.ok); });
      renderLogs();
    } else if (r.view === "task") {
      loadAndRender("GET_TASK_DETAIL", { id: r.id }, function (d) { setBadge(!!d.ok); renderTaskDetail(d, r.id); });
      startRefresh(function () {
        loadAndRender("GET_TASK_DETAIL", { id: r.id }, function (d) { setBadge(!!d.ok); renderTaskDetail(d, r.id); });
      }, 5000);
    } else if (r.view === "editor") {
      renderEditor({ id: r.id || "new" });
      read("GET_TASK_DETAIL", { id: r.id }).then(function (d) { setBadge(!!d.ok); renderTaskDetail(d, r.id); });
      read("GET_TASK_DETAIL", { id: r.id }).then(function (d) { setBadge(!!d.ok); renderTaskDetail(d, r.id); });
    } else {
      loadAndRender("GET_SUMMARY", {}, function (d) { setBadge(!!d.ok); renderDashboard(d); });
      startRefresh(function () {
        loadAndRender("GET_SUMMARY", {}, function (d) { setBadge(!!d.ok); renderDashboard(d); });
      }, 5000);
    }
  }

  window.addEventListener("hashchange", route);
  document.addEventListener("DOMContentLoaded", route);
})();
