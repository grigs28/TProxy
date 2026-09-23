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
  table.innerHTML = "<thead><tr><th>配置</th><th>端口</th><th>缓存区</th></tr></thead>";
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
    tr.append(td1, td2, td3);
    tb.appendChild(tr);
  }
  table.appendChild(tb);
  box.appendChild(table);
}

function setHealth(ok, text) {
  $("health-dot").className = "dot " + (ok ? "ok" : "bad");
  $("health-text").textContent = text;
}

async function load() {
  try {
    await getJSON("/api/status");
    setHealth(true, "管理端正常");
  } catch (e) {
    setHealth(false, "管理端无响应");
    return;
  }

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

load();
setInterval(load, 30000);
