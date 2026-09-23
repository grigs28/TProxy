// TProxy 管理界面前端（免构建，原生 JS）
//
// 设计取向：这是运维工具，一切为「快速判断当前是否正常」服务。
// 空态必须写明原因而非静默留白 —— 旧 proxy-manager 正因「显示为空却不报错」，
// 让缓存完全失效持续了数月无人察觉。

const $ = (id) => document.getElementById(id);

const TYPE_LABEL = {
  os: "system", registry: "docker", git: "git",
  python: "python", nodejs: "node", java: "java",
};

function fmtBytes(n) {
  if (!n) return "0";
  const u = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n < 10 ? n.toFixed(1) : Math.round(n)} ${u[i]}`;
}

function emptyBox(msg) {
  const d = document.createElement("div");
  d.className = "empty";
  d.textContent = msg;
  return d;
}

async function getJSON(path) {
  const r = await fetch(path, { cache: "no-store" });
  if (!r.ok) throw new Error(`${path} → HTTP ${r.status}`);
  return r.json();
}

async function postJSON(path, body) {
  const r = await fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body || {}),
  });
  // 401 表示未登录（会话过期），直接回登录页而不是抛一句看不懂的错误
  if (r.status === 401) {
    window.location.reload();
    throw new Error("登录状态已过期");
  }
  const d = await r.json().catch(() => ({}));
  if (d && d.msg !== undefined) return d;
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return d;
}

// ---- 缓存总览 ----
// 签名元素：未启用显示为虚线空槽，一眼可辨「哪类没在工作」。
function renderCache(types) {
  const box = $("cache-list");
  box.innerHTML = "";
  const enabled = types.filter((t) => t.enabled).length;
  $("cache-count").textContent = `${enabled}/${types.length} 已启用`;

  if (!types.length) {
    box.appendChild(emptyBox("未读取到缓存目录"));
    return;
  }

  // 以最大占用为基准，让条形的相对长度可比较。
  // 但若全部为 0（尚未缓存任何内容），不做缩放，避免除零后出现满格误导。
  const max = Math.max(...types.map((t) => t.bytes), 1);
  const allZero = types.every((t) => t.bytes === 0);

  for (const t of types) {
    const row = document.createElement("div");
    row.className = "cache-row";

    const name = document.createElement("div");
    name.className = "cache-name";
    name.textContent = TYPE_LABEL[t.type] || t.type;

    const bar = document.createElement("div");
    bar.className = "bar" + (t.enabled ? "" : " off");
    const fill = document.createElement("i");
    const pct = allZero ? 0 : Math.max(2, Math.round((t.bytes / max) * 100));
    fill.style.width = pct + "%";
    bar.appendChild(fill);

    const size = document.createElement("div");
    size.className = "cache-size";
    size.textContent = t.enabled
      ? (t.bytes ? fmtBytes(t.bytes) : "空")
      : "—";

    const state = document.createElement("div");
    state.className = "cache-state " + (t.enabled ? "on" : "off");
    state.textContent = t.enabled ? "启用" : "未启用";

    row.append(name, bar, size, state);
    box.appendChild(row);
  }
}

// ---- 缓存命中率 ----
// 回答「缓存到底有没有在起作用」——这正是本项目最初的痛点：
// 旧系统崩溃 1.7 万次、缓存长期为零，却因「看不见」而无人察觉。
function renderHitrate(rows) {
  const box = $("hit-list");
  box.innerHTML = "";

  const judged = rows.filter((r) => r.rate !== null);
  $("hit-count").textContent = judged.length
    ? `${judged.length} 类有数据`
    : "";

  if (!rows.length) {
    box.appendChild(emptyBox("未读取到日志目录"));
    return;
  }

  const table = document.createElement("table");
  const thead = document.createElement("thead");
  thead.innerHTML =
    "<tr><th>类型</th><th>命中率</th><th>命中</th><th>回源</th><th>不适用</th></tr>";
  table.appendChild(thead);

  const tb = document.createElement("tbody");
  for (const r of rows) {
    const tr = document.createElement("tr");

    const td1 = document.createElement("td");
    td1.className = "mono";
    td1.textContent = TYPE_LABEL[r.type] || r.type;

    const td2 = document.createElement("td");
    td2.className = "mono";
    if (r.backend_cached) {
      // registry/git 的缓存在各自后端，tengine 日志无标记 ——
      // 必须明确说明，而不是显示 0% 让人以为缓存失效
      td2.className = "mono muted";
      td2.textContent = "后端自缓存";
      td2.title = "该类型的缓存由 registry:2 / gitcache 各自管理，nginx 层不参与";
      tr.append(td1, td2);
      for (let i = 0; i < 3; i++) tr.appendChild(document.createElement("td"));
      tb.appendChild(tr);
      continue;
    }

    if (r.rate === null) {
      td2.className = "mono muted";
      td2.textContent = "无数据";
      td2.title = "该类的日志中没有命中记录（可能尚无流量）";
    } else {
      // 命中率染色：低于 50% 值得注意，低于 20% 明显异常
      td2.className = "mono " + (r.rate >= 50 ? "" : r.rate >= 20 ? "warn" : "bad");
      td2.textContent = `${r.rate}%`;
    }

    const mk = (v, cls) => {
      const td = document.createElement("td");
      td.className = "mono " + (cls || "muted");
      td.textContent = v;
      return td;
    };
    tr.append(
      td1,
      td2,
      mk(r.hit),
      mk(r.miss),
      mk(r.uncached || 0)
    );
    tb.appendChild(tr);
  }
  table.appendChild(tb);
  box.appendChild(table);
}

// ---- 劫持规则 ----
// 用「域名 → 目标」的映射对呈现，直接体现「劫持」语义。
function renderRules(data) {
  const box = $("rule-list");
  box.innerHTML = "";
  const rules = data.rules || [];
  $("rule-count").textContent = rules.length ? `${rules.length} 条` : "";

  if (!rules.length) {
    box.appendChild(emptyBox("未解析到劫持规则 —— 检查 dnsmasq 配置路径与内容"));
    return;
  }

  const table = document.createElement("table");
  table.innerHTML = "<thead><tr><th>域名</th><th>解析为</th></tr></thead>";
  const tb = document.createElement("tbody");
  for (const r of rules) {
    const tr = document.createElement("tr");
    const td1 = document.createElement("td");
    td1.className = "mono";
    td1.textContent = r.domain;
    const td2 = document.createElement("td");
    td2.className = "mono muted";
    // 用 DOM 方法而非 innerHTML 拼接：即便 target 来自本机配置，
    // 也不该让配置内容有机会成为可执行标记
    const arrow = document.createElement("span");
    arrow.className = "arrow";
    arrow.textContent = "→";
    td2.append(arrow, document.createTextNode(r.target));
    tr.append(td1, td2);
    tb.appendChild(tr);
  }
  table.appendChild(tb);
  box.appendChild(table);
}

// ---- 证书 ----
function renderCerts(certs) {
  const box = $("cert-list");
  box.innerHTML = "";
  $("cert-count").textContent = certs.length ? `${certs.length} 张` : "";

  if (!certs.length) {
    box.appendChild(emptyBox("未找到证书 —— 检查 ca/certs 目录"));
    return;
  }

  // 最紧急的排在前面：运维关心的是「哪个快过期了」
  const sorted = [...certs].sort((a, b) => a.days_left - b.days_left);
  const table = document.createElement("table");
  table.innerHTML = "<thead><tr><th>域名</th><th>剩余</th></tr></thead>";
  const tb = document.createElement("tbody");
  for (const c of sorted) {
    const tr = document.createElement("tr");
    const td1 = document.createElement("td");
    td1.className = "mono";
    td1.textContent = c.domain;
    const td2 = document.createElement("td");
    td2.className = "mono " + (c.expired ? "bad" : c.expiring_soon ? "warn" : "muted");
    td2.textContent = c.expired ? "已过期" : `${c.days_left} 天`;
    tr.append(td1, td2);
    tb.appendChild(tr);
  }
  table.appendChild(tb);
  box.appendChild(table);
}

// ---- 分流入口 ----
function renderServers(servers) {
  const box = $("server-list");
  box.innerHTML = "";
  $("server-count").textContent = servers.length ? `${servers.length} 个文件` : "";

  if (!servers.length) {
    box.appendChild(emptyBox("未解析到分流配置 —— 检查 tengine/conf.d 目录"));
    return;
  }

  const table = document.createElement("table");
  table.innerHTML =
    "<thead><tr><th>配置</th><th>端口</th><th>缓存区</th><th></th></tr></thead>";
  const tb = document.createElement("tbody");
  for (const s of servers) {
    const tr = document.createElement("tr");
    const td1 = document.createElement("td");
    td1.className = "mono";
    td1.textContent = s.file;
    td1.title = (s.server_name || []).join(", ");
    const td2 = document.createElement("td");
    td2.className = "mono muted";
    td2.textContent = (s.listen || []).join("/") || "—";
    const td3 = document.createElement("td");
    td3.className = "mono muted";
    td3.textContent = s.cache_zone || "—";

    const td4 = document.createElement("td");
    td4.style.textAlign = "right";
    const btn = document.createElement("button");
    btn.className = "btn";
    btn.textContent = "编辑";
    btn.addEventListener("click", () => openConfd(s.file));
    td4.appendChild(btn);

    tr.append(td1, td2, td3, td4);
    tb.appendChild(tr);
  }
  table.appendChild(tb);
  box.appendChild(table);
}

// ---- 添加上游 ----
async function openUpstream() {
  const dlg = $("upstream-dialog");
  $("up-domain").value = "";
  $("up-preview").innerHTML = "";
  $("up-msg").textContent = "";
  $("up-apply-btn").disabled = true;

  try {
    const d = await getJSON("/api/upstream/categories");
    const sel = $("up-category");
    sel.innerHTML = "";
    for (const c of d.categories || []) {
      const o = document.createElement("option");
      o.value = c;
      o.textContent = c;
      sel.appendChild(o);
    }
  } catch (e) { /* 下拉为空时后面会提示 */ }

  dlg.showModal();
}

async function previewUpstream() {
  const domain = $("up-domain").value.trim();
  const category = $("up-category").value;
  const box = $("up-preview");
  const msg = $("up-msg");
  box.innerHTML = "";
  msg.textContent = "";
  $("up-apply-btn").disabled = true;

  if (!domain) { msg.className = "msg err"; msg.textContent = "请填写域名"; return; }

  try {
    const d = await postJSON("/api/upstream/preview", { domain, category });
    if (!d.ok) { msg.className = "msg err"; msg.textContent = d.msg; return; }

    const wrap = document.createElement("div");
    wrap.className = "changes";
    for (const c of d.changes || []) {
      const el = document.createElement("div");
      el.className = "change";
      const where = document.createElement("div");
      where.className = "where";
      where.textContent = `${c.file} · ${c.action}`;
      const diff = document.createElement("div");
      diff.className = "diff";
      diff.textContent = c.diff;
      const desc = document.createElement("div");
      desc.className = "desc";
      desc.textContent = c.desc;
      el.append(where, diff, desc);
      wrap.appendChild(el);
    }
    box.appendChild(wrap);
    $("up-apply-btn").disabled = false;
    if (d.note) { msg.className = "msg"; msg.textContent = d.note; }
  } catch (e) {
    msg.className = "msg err";
    msg.textContent = `预览失败：${e.message}`;
  }
}

async function applyUpstream() {
  const domain = $("up-domain").value.trim();
  const category = $("up-category").value;
  const msg = $("up-msg");
  $("up-apply-btn").disabled = true;
  msg.className = "msg";
  msg.textContent = "执行中…";

  try {
    const d = await postJSON("/api/upstream/apply", { domain, category });
    if (!d.ok) { msg.className = "msg err"; msg.textContent = d.msg; return; }
    msg.className = "msg ok";
    // 把重启命令一并显示 —— 不自动重启，避免界面替人做生产动作
    msg.textContent = d.msg + (d.restart_hint ? `　生效需执行：${d.restart_hint}` : "");
    load();
  } catch (e) {
    msg.className = "msg err";
    msg.textContent = `添加失败：${e.message}`;
    $("up-apply-btn").disabled = false;
  }
}

// ---- 编辑分流配置 ----
let editingConf = "";

async function openConfd(name) {
  const dlg = $("confd-dialog");
  $("confd-title").textContent = `编辑 ${name}`;
  $("confd-msg").textContent = "";
  editingConf = name;
  try {
    const d = await getJSON(`/api/confd/${encodeURIComponent(name)}`);
    $("confd-content").value = d.content || "";
    dlg.showModal();
  } catch (e) {
    alert(`读取失败：${e.message}`);
  }
}

async function saveConfd() {
  const msg = $("confd-msg");
  msg.className = "msg";
  msg.textContent = "保存中…";
  try {
    const d = await postJSON(`/api/confd/${encodeURIComponent(editingConf)}`,
                             { content: $("confd-content").value });
    if (!d.ok) { msg.className = "msg err"; msg.textContent = d.msg; return; }
    msg.className = "msg ok";
    msg.textContent = d.msg + (d.restart_hint ? `　生效需执行：${d.restart_hint}` : "");
  } catch (e) {
    msg.className = "msg err";
    msg.textContent = `保存失败：${e.message}`;
  }
}

async function createConfd() {
  const name = prompt("新分流配置的文件名（如 newrepo.conf）");
  if (!name) return;
  const d = await postJSON("/api/confd", { name });
  if (!d.ok) { alert(d.msg); return; }
  alert(d.msg + "\n\n生效需执行：" + (d.restart_hint || ""));
  load();
}

const ALL_BOXES = ["cache-list", "hit-list", "rule-list", "cert-list", "server-list"];

function setHealth(ok, text) {
  $("health-dot").className = "dot " + (ok ? "ok" : "bad");
  $("health-text").textContent = text;
}

function renderHeader(st) {
  if (st.version) $("version").textContent = "v" + st.version;

  const u = st.user || {};
  const name = u.display_name || u.username || "";
  if (name) {
    $("user-name").textContent = name;
    $("host-sep").hidden = false;
    $("logout-link").hidden = false;
  }
}

async function load() {
  let st;
  try {
    st = await getJSON("/api/status");
    setHealth(true, "管理端正常");
  } catch (e) {
    setHealth(false, "管理端无响应");
    // 必须给各区块填上明确原因 —— 否则它们会永远停在「读取中…」，
    // 与「空态写明原因」的规则相悖
    for (const id of ALL_BOXES) {
      $(id).innerHTML = "";
      $(id).appendChild(emptyBox("管理端无响应"));
    }
    return;
  }
  renderHeader(st);

  const jobs = [
    ["/api/cache", "cache-list", (d) => renderCache(d.types || [])],
    ["/api/hitrate", "hit-list", (d) => renderHitrate(d.hitrate || [])],
    ["/api/rules", "rule-list", renderRules],
    ["/api/certs", "cert-list", (d) => renderCerts(d.certs || [])],
  ];
  for (const [path, boxId, fn] of jobs) {
    try {
      fn(await getJSON(path));
    } catch (e) {
      // 单个接口失败不应让整页空白 —— 明确标出是哪一项失败了
      $(boxId).innerHTML = "";
      $(boxId).appendChild(emptyBox(`读取失败：${e.message}`));
    }
  }

  // 分流入口与劫持规则同源
  try {
    const d = await getJSON("/api/rules");
    renderServers(d.servers || []);
  } catch (e) {
    $("server-list").innerHTML = "";
    $("server-list").appendChild(emptyBox(`读取失败：${e.message}`));
  }
}

// ---- 事件绑定 ----
function bindEvents() {
  // 添加上游
  $("add-upstream-btn").addEventListener("click", openUpstream);
  $("up-preview-btn").addEventListener("click", previewUpstream);
  $("up-apply-btn").addEventListener("click", applyUpstream);
  $("up-cancel").addEventListener("click", () => $("upstream-dialog").close());
  // 域名改动后需重新预览才允许提交 —— 避免「预览的是 A、提交的是 B」
  $("up-domain").addEventListener("input", () => {
    $("up-apply-btn").disabled = true;
    $("up-preview").innerHTML = "";
  });
  $("up-category").addEventListener("change", () => {
    $("up-apply-btn").disabled = true;
    $("up-preview").innerHTML = "";
  });
  // 分流配置
  $("add-confd-btn").addEventListener("click", createConfd);
  $("confd-save").addEventListener("click", saveConfd);
  $("confd-cancel").addEventListener("click", () => $("confd-dialog").close());
}

bindEvents();
load();
setInterval(load, 30000);
