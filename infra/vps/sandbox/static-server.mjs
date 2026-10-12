// 沙盒内辅助 HTTP 服务(只在内网 docker_play 上暴露,由边缘 Caddy 转发)。
//
// 为什么需要它:
//   1. 提供「裁剪版 Web UI」(/srv/app-dist)—— opencode 只出 API,不再由它发 UI;
//   2. 净化模型/配置接口(去掉网关密钥,只暴露网关默认模型);
//   3. 工作台页(/__hub)与 /workspace 只读预览(/preview/*,含访客后端 8000 反代)。
//
// 目标 opencode = v2.0.27(API 全部在 /api/* 下;模型/配置接口为
// /api/provider、/api/model、/api/model/default、/api/config)。
//
// 只用 node 内置模块,无依赖;node 是官方 opencode 镜像自带的运行时。
import { createServer, request as httpRequest } from "node:http";
import { stat, readFile } from "node:fs/promises";
import { createReadStream } from "node:fs";
import { extname, join, resolve, sep } from "node:path";
import { connect as netConnect } from "node:net";

const PORT = Number(process.env.SANDBOX_HELPER_PORT || 47311);
const WORKSPACE = "/workspace";
const APP_DIST = process.env.SANDBOX_APP_DIST || "/srv/app-dist";
const HUB_FILE = process.env.SANDBOX_HUB_FILE || "/srv/hub.html";
const SESSION_ID = process.env.PLAYGROUND_SESSION_ID || "ses_guest";
const UPSTREAM = process.env.SANDBOX_UPSTREAM || "http://127.0.0.1:4096";
// opencode v2.0.x 绑 0.0.0.0 时强制 Basic 鉴权;本服务直连容器内 127.0.0.1:4096,
// 必须自带凭据(由 compose 注入,与边缘 Caddy 用的是同一个值)。
const UPSTREAM_AUTH = process.env.SANDBOX_UPSTREAM_AUTH || "";
// 访客应用的**约定后端端口**:预览里的非静态请求(如 /api/*)会反代到它。
const APP_PORT = Number(process.env.SANDBOX_APP_PORT || 8000);

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".htm": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".map": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".avif": "image/avif",
  ".ico": "image/x-icon",
  ".txt": "text/plain; charset=utf-8",
  ".md": "text/plain; charset=utf-8",
  ".webmanifest": "application/manifest+json",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".wasm": "application/wasm",
  ".mp4": "video/mp4",
  ".webm": "video/webm",
  ".pdf": "application/pdf",
};

const baseHeaders = { "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer" };
const send = (res, status, body, headers = {}) => {
  res.writeHead(status, { ...baseHeaders, ...headers });
  res.end(body);
};
const notFound = (res) => send(res, 404, "not found", { "Content-Type": "text/plain; charset=utf-8" });
const json = (res, obj) =>
  send(res, 200, JSON.stringify(obj), { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });

// ---------- Service Worker:只缓存不可变的 /_assets/*(带内容哈希) ----------
const SW_JS = `self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil((async () => {
  const keys = await caches.keys();
  await Promise.all(keys.filter((k) => k !== "zx-assets-v1").map((k) => caches.delete(k)));
  await self.clients.claim();
})()));
self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;
  let url; try { url = new URL(req.url); } catch (err) { return; }
  if (url.origin !== self.location.origin || !url.pathname.startsWith("/_assets/")) return;
  e.respondWith((async () => {
    const cache = await caches.open("zx-assets-v1");
    const hit = await cache.match(req);
    if (hit) return hit;
    const res = await fetch(req);
    if (res && res.ok) cache.put(req, res.clone());
    return res;
  })());
});`;
async function serveSw(req, res) {
  res.writeHead(200, { ...baseHeaders, "Content-Type": "text/javascript; charset=utf-8", "Cache-Control": "no-cache", "Service-Worker-Allowed": "/" });
  res.end(req.method === "HEAD" ? undefined : SW_JS);
}

// ---------- 外壳注入(裁剪版 UI 之上再做「访客锁定」)----------
// 裁剪版已经去掉了标题栏/标签/设置/新建会话;这里再隐藏残留的「模型选择/变体/更多选项/
// 会话详情/更改面板」等入口,并拦掉管理类键位与斜杠命令,注入 Plan/Build 切换。
const SHELL_CSS = [
  'header,aside,[data-slot=user-message-meta],[data-slot=text-part-meta],[data-slot="tabs"]{display:none!important}',
  // 窄栏下的「Session | Changes | More...」分段条(会点开更改/更多菜单)——整条隐藏
  '[aria-label="Session view"]{display:none!important}',
  'button[data-action="composer-model"],button[aria-label="Choose model variant"],button[aria-label="More options"],button[aria-label="Toggle review"],button[aria-label="Session details"],button[aria-label="View context usage"],button[data-component="icon-button-v2"][aria-haspopup="true"]:not([data-action]){display:none!important}',
  '[class*="md:max-w-200"],[class*="2xl:max-w-[1000px]"]{max-width:none!important}',
  '[data-zx-ag]{display:inline-flex;gap:4px;margin:0 2px;padding:2px;align-items:center}',
  '[data-zx-ag] button{font:12px/1.2 system-ui;color:inherit;background:transparent;border:1px solid rgba(128,128,128,.4);border-radius:999px;padding:2px 10px;cursor:pointer}',
  '[data-zx-ag] button.on{background:#3574f0;border-color:#3574f0;color:#fff}',
  '[data-sonner-toaster],[data-sonner-toast]{display:none!important}',
].join("");

const SHELL_CLIENT = `(function(){
var S=JSON.stringify(location.pathname.replace(/\\/+$/,""));
var AG="zx-sandbox-agent";
try{var RK="settings.v3",rw=localStorage.getItem(RK),ro=rw?JSON.parse(rw):{};ro=(ro&&typeof ro==="object")?ro:{};ro.general=(ro.general&&typeof ro.general==="object")?ro.general:{};if(ro.general.showReasoningSummaries!==true){ro.general.showReasoningSummaries=true;localStorage.setItem(RK,JSON.stringify(ro));}}catch(err){}
try{if(!localStorage.getItem("highlights.v1"))localStorage.setItem("highlights.v1",JSON.stringify({version:"seen"}));}catch(err){}
var SEL='[data-slot=user-message-meta],[data-slot=text-part-meta]';
function hideNow(n){try{var e=n.querySelectorAll(SEL);for(var i=0;i<e.length;i++)e[i].style.setProperty("display","none","important");}catch(err){}}
function hideAll(){try{var e=document.querySelectorAll(SEL);for(var i=0;i<e.length;i++)e[i].style.setProperty("display","none","important");}catch(err){}}
function ag(){try{var m=document.querySelector('button[data-action="composer-model"]');if(!m||!m.parentElement)return;var host=m.parentElement,cur=localStorage.getItem(AG)||"plan",bar=document.querySelector("[data-zx-ag]");if(bar&&bar.dataset.v===cur)return;if(!bar){bar=document.createElement("div");bar.setAttribute("data-zx-ag","1");host.appendChild(bar);}bar.dataset.v=cur;bar.textContent="";["plan","build"].forEach(function(a){var b=document.createElement("button");b.textContent=a==="plan"?"Plan":"Build";if(a===cur)b.className="on";b.addEventListener("click",function(){try{fetch("/api/session/ses_guest/agent",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({agent:a})});}catch(err){}localStorage.setItem(AG,a);bar.dataset.v="";ag();});bar.appendChild(b);});}catch(err){}}
function guard(){var p=location.pathname;if((p==="/"||p==="/global"||p==="/global/")&&S)location.replace(S);}
function syncAgent(){var want=localStorage.getItem(AG)||"plan";try{fetch("/api/session/ses_guest",{headers:{Accept:"application/json"}}).then(function(r){return r.json();}).then(function(d){var cur=d&&d.data&&d.data.agent;if(cur&&cur!==want)return fetch("/api/session/ses_guest/agent",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({agent:want})}).catch(function(){});}).catch(function(){});}catch(err){}}
var q=[],sched=false;
function flush(){sched=false;var l=q;q=[];for(var i=0;i<l.length;i++)hideNow(l[i]);ag();}
function onMut(recs){var dirty=false;for(var i=0;i<recs.length;i++){var r=recs[i];if(r.type!=="childList")continue;dirty=true;for(var j=0;j<r.addedNodes.length;j++){var a=r.addedNodes[j];if(a.nodeType===1)q.push(a);}}if(dirty&&!sched){sched=true;requestAnimationFrame(flush);}}
function run(){hideAll();ag();}
new MutationObserver(onMut).observe(document.documentElement,{childList:true,subtree:true});
document.addEventListener("DOMContentLoaded",function(){run();syncAgent();});run();guard();setInterval(guard,800);
function keyb(ev){if(!(ev.metaKey||ev.ctrlKey))return;var k=(ev.key||"").toLowerCase();if(k==="k"||k==="n"||k===","||k==="p"||(k==="r"&&ev.shiftKey)){ev.preventDefault();ev.stopImmediatePropagation();}}
window.addEventListener("keydown",keyb,true);document.addEventListener("keydown",keyb,true);
function slashG(ev){var k=ev.key;if(k!=="/"&&k!=="Enter")return;var t=ev.target;var pi=t&&t.closest?t.closest('[data-component="composer-editor"]'):null;if(!pi)return;var x=(pi.textContent||"").trim();if(k==="/"&&x===""){ev.preventDefault();ev.stopImmediatePropagation();}if(k==="Enter"&&!ev.shiftKey&&x.charAt(0)==="/"){ev.preventDefault();ev.stopImmediatePropagation();}}
window.addEventListener("keydown",slashG,true);
try{if("serviceWorker" in navigator)navigator.serviceWorker.register("/sw.js");}catch(err){}
})();`;

let shellCache = null; // { html, at }
async function readAppIndex() {
  const now = Date.now();
  if (!shellCache || now - shellCache.at > 30000) {
    const html = await readFile(join(APP_DIST, "index.html"), "utf8");
    shellCache = { html, at: now };
  }
  return shellCache.html;
}

function injectShell(html) {
  const preload = '<link rel="preload" as="font" type="font/ttf" href="/assets/Inter.ttf" crossorigin>';
  const inject = "<style>" + SHELL_CSS + "</style>" + preload + "<script>" + SHELL_CLIENT + "</scr" + "ipt>";
  if (html.includes("<head>")) return html.replace("<head>", "<head>" + inject);
  if (html.includes("</head>")) return html.replace("</head>", inject + "</head>");
  return inject + html;
}

// ---------- 裁剪版 UI 静态资源(/srv/app-dist)----------
async function serveDistFile(req, res, pathname) {
  let rel;
  try {
    rel = decodeURIComponent(pathname);
  } catch {
    return notFound(res);
  }
  if (rel.includes("\0")) return notFound(res);
  const target = resolve(join(APP_DIST, rel));
  if (target !== APP_DIST && !target.startsWith(APP_DIST + sep)) return notFound(res);
  let st = null;
  try {
    st = await stat(target);
  } catch {}
  if (!st || !st.isFile()) return notFound(res);
  res.writeHead(200, {
    ...baseHeaders,
    "Content-Type": MIME[extname(target).toLowerCase()] || "application/octet-stream",
    "Content-Length": st.size,
    "Last-Modified": st.mtime.toUTCString(),
    "Cache-Control": "no-store",
  });
  if (req.method === "HEAD") return res.end();
  createReadStream(target).pipe(res);
}

async function serveShell(req, res) {
  let html;
  try {
    html = injectShell(await readAppIndex());
  } catch {
    return send(res, 200, '<!doctype html><meta charset=utf-8><p style="font:14px system-ui;padding:2rem">沙盒正在启动，请稍后刷新。</p>', {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
    });
  }
  res.writeHead(200, { ...baseHeaders, "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
  res.end(req.method === "HEAD" ? undefined : html);
}

// 预览根还没 index.html 时的友好提示(右栏不显示裸 404)
const PREVIEW_HINT =
  '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>访客的网站</title>' +
  '<body style="font:14px/1.7 system-ui,sans-serif;padding:2.5rem;color:#52525b">' +
  "<h2 style=\"font-size:16px;font-weight:600;margin:0 0 .6rem;color:#18181b\">还没有网页</h2>" +
  "<p>在左侧会话里让助手创建 <code>index.html</code>(或直接丢个 HTML 进去),保存后这里会实时刷新。</p></body></html>";

// opencode 可能比本服务晚就绪(同一容器内并发启动),取上游时重试几次。
async function upstream(path, tries = 5, headers = {}) {
  let lastErr;
  for (let i = 0; i < tries; i++) {
    try {
      return await fetch(UPSTREAM + path, {
        headers: { accept: "application/json", ...(UPSTREAM_AUTH ? { authorization: UPSTREAM_AUTH } : {}), ...headers },
      });
    } catch (err) {
      lastErr = err;
      await new Promise((r) => setTimeout(r, 300));
    }
  }
  throw lastErr;
}

// 净化:去掉网关密钥,只暴露「博客 AI 网关」与其默认模型。
// opencode v2.0.x 的响应里 settings 会带 apiKey(实测),必须剥掉。
function stripProviderKeys(provider) {
  if (!provider || typeof provider !== "object") return provider;
  const { settings, ...rest } = provider;
  if (settings && typeof settings === "object") {
    const { apiKey, ...s } = settings;
    if (Object.keys(s).length) rest.settings = s;
  }
  return rest;
}
function stripModelSettings(model) {
  if (!model || typeof model !== "object") return model;
  const { settings, ...rest } = model;
  return rest;
}

async function serveSanitizedConfig(res, search) {
  let body;
  try {
    const r = await upstream("/api/config" + (search || ""));
    if (!r.ok) return send(res, r.status, "config unavailable", { "Content-Type": "text/plain; charset=utf-8" });
    body = await r.json();
  } catch {
    return send(res, 503, "config unavailable", { "Content-Type": "text/plain; charset=utf-8" });
  }
  // v2.0.x 的 /api/config 返回「配置文档数组」,provider 块(含网关密钥)在
  // 每一项的 info.providers / info.provider 里;老形状是对象。两种都处理。
  const scrub = (obj) => {
    if (!obj || typeof obj !== "object") return;
    delete obj.providers;
    delete obj.provider;
  };
  if (Array.isArray(body)) {
    for (const entry of body) scrub(entry && entry.info);
  } else {
    scrub(body);
  }
  return json(res, body);
}

async function serveSanitizedProvider(res, search) {
  let body;
  try {
    const r = await upstream("/api/provider" + (search || ""));
    if (!r.ok) return send(res, r.status, "provider unavailable", { "Content-Type": "text/plain; charset=utf-8" });
    body = await r.json();
  } catch {
    return send(res, 503, "provider unavailable", { "Content-Type": "text/plain; charset=utf-8" });
  }
  const data = Array.isArray(body.data) ? body.data.filter((p) => p && p.id === "zxgw").map(stripProviderKeys) : [];
  return json(res, { ...body, data });
}

async function serveSanitizedModel(res, search) {
  let body;
  try {
    const r = await upstream("/api/model" + (search || ""));
    if (!r.ok) return send(res, r.status, "model unavailable", { "Content-Type": "text/plain; charset=utf-8" });
    body = await r.json();
  } catch {
    return send(res, 503, "model unavailable", { "Content-Type": "text/plain; charset=utf-8" });
  }
  const data = Array.isArray(body.data) ? body.data.filter((m) => m && m.providerID === "zxgw").map(stripModelSettings) : [];
  return json(res, { ...body, data });
}

async function serveSanitizedModelDefault(res, search) {
  let body;
  try {
    const r = await upstream("/api/model/default" + (search || ""));
    if (!r.ok) return send(res, r.status, "model unavailable", { "Content-Type": "text/plain; charset=utf-8" });
    body = await r.json();
  } catch {
    return send(res, 503, "model unavailable", { "Content-Type": "text/plain; charset=utf-8" });
  }
  if (body && body.data && body.data.providerID === "zxgw") body.data = stripModelSettings(body.data);
  return json(res, body);
}

// 会话历史条数上限:访客共享会话会无限累积(实测 170+ 条),时间线虚拟滚动在向上翻页时
// 反复测高 → 视觉上「被往下拉」。这里做**非破坏性**截断:只让 SPA 拿到最近 N 条、且不再
// 向更早翻页(清空 next 游标);服务端数据不动。
const HISTORY_LIMIT = Number(process.env.PLAYGROUND_HISTORY_LIMIT || 40);
async function serveCappedMessages(req, res, pathname, search) {
  const params = new URLSearchParams(search || "");
  if (params.has("cursor")) return json(res, { data: [], cursor: { previous: null, next: null } });
  params.set("limit", String(HISTORY_LIMIT));
  if (!params.has("order")) params.set("order", "desc");
  let body;
  try {
    const r = await upstream(pathname + "?" + params.toString());
    if (!r.ok) return send(res, r.status, "message unavailable", { "Content-Type": "text/plain; charset=utf-8" });
    body = await r.json();
  } catch {
    return send(res, 503, "message unavailable", { "Content-Type": "text/plain; charset=utf-8" });
  }
  if (body && body.cursor) body.cursor.next = null;
  return json(res, body);
}

async function serveHub(req, res) {
  let html;
  try {
    html = (await readFile(HUB_FILE, "utf8")).replaceAll("__SESSION_ID__", SESSION_ID);
  } catch {
    return send(res, 500, "hub unavailable", { "Content-Type": "text/plain; charset=utf-8" });
  }
  // 预取:从裁剪版 index.html 解析出入口 bundle,注入 modulepreload + 字体预载。
  try {
    const shell = await readAppIndex();
    const m = shell.match(/\/_assets\/index-[A-Za-z0-9_-]+\.js/);
    const preload =
      (m ? '<link rel="modulepreload" crossorigin href="' + m[0] + '">' : "") +
      '<link rel="preload" as="font" type="font/ttf" href="/assets/Inter.ttf" crossorigin>';
    if (html.includes("<head>")) html = html.replace("<head>", "<head>" + preload);
  } catch {}
  res.writeHead(200, { ...baseHeaders, "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
  res.end(req.method === "HEAD" ? undefined : html);
}

async function serveFile(req, res, file) {
  let st;
  try {
    st = await stat(file);
  } catch {
    return notFound(res);
  }
  if (!st.isFile()) return notFound(res);
  res.writeHead(200, {
    ...baseHeaders,
    "Content-Type": MIME[extname(file).toLowerCase()] || "application/octet-stream",
    "Content-Length": st.size,
    "Last-Modified": st.mtime.toUTCString(),
    "Cache-Control": "no-store",
  });
  if (req.method === "HEAD") return res.end();
  createReadStream(file).pipe(res);
}

// 访客后端是否在约定端口监听
function appUp() {
  return new Promise((resolve) => {
    const s = netConnect({ host: "127.0.0.1", port: APP_PORT });
    let done = false;
    const finish = (v) => { if (done) return; done = true; s.destroy(); resolve(v); };
    s.setTimeout(400);
    s.once("connect", () => finish(true));
    s.once("timeout", () => finish(false));
    s.once("error", () => finish(false));
  });
}

// 「改模型」强制为网关默认:UI 每次发送前会 POST /api/session/<id>/model。
// 访客无权选模型 → 这里**忽略请求体**,一律写死成网关默认模型再转发,保证
// 即便有人手工构造请求也换不了模型。
const FORCED_MODEL = JSON.stringify({ model: { id: "gateway-default", providerID: "zxgw" } });
function serveForcedModel(req, res, pathname, search) {
  const headers = {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(FORCED_MODEL),
    ...(UPSTREAM_AUTH ? { authorization: UPSTREAM_AUTH } : {}),
  };
  const up = httpRequest(
    { host: "127.0.0.1", port: 4096, method: "POST", path: pathname + (search || ""), headers },
    (ur) => {
      res.writeHead(ur.statusCode || 502, ur.headers);
      ur.pipe(res);
    },
  );
  up.on("error", () => {
    if (res.headersSent) res.end();
    else send(res, 502, "upstream error", { "Content-Type": "text/plain; charset=utf-8" });
  });
  // 丢弃客户端请求体(不读取内容),直接发送写死后的模型
  req.resume();
  up.end(FORCED_MODEL);
}

// 把请求整体反代到访客后端(方法/请求体/响应体都透传)
function proxyToApp(req, res, path, search) {
  const headers = { ...req.headers, host: `127.0.0.1:${APP_PORT}` };
  delete headers["connection"];
  const up = httpRequest(
    { host: "127.0.0.1", port: APP_PORT, method: req.method, path: path + (search || ""), headers },
    (ur) => {
      res.writeHead(ur.statusCode || 502, ur.headers);
      ur.pipe(res);
    },
  );
  up.on("error", () => {
    if (res.headersSent) res.end();
    else send(res, 502, "app unavailable", { "Content-Type": "text/plain; charset=utf-8" });
  });
  req.pipe(up);
}

async function servePreview(req, res, pathname, search) {
  const isRead = req.method === "GET" || req.method === "HEAD";
  let rel = pathname.replace(/^\/preview\/?/, "");
  try {
    rel = decodeURIComponent(rel);
  } catch {
    return send(res, 400, "bad path");
  }
  if (rel.includes("\0")) return send(res, 400, "bad path");
  const target = resolve(join(WORKSPACE, rel));
  if (target !== WORKSPACE && !target.startsWith(WORKSPACE + sep)) return send(res, 403, "forbidden");

  // ① 静态文件优先:存在就直接读(不列目录)
  if (isRead) {
    let st = null;
    try { st = await stat(target); } catch {}
    if (st && st.isFile()) return serveFile(req, res, target);
    if (st && st.isDirectory()) {
      const idx = join(target, "index.html");
      let st2 = null;
      try { st2 = await stat(idx); } catch {}
      if (st2 && st2.isFile()) return serveFile(req, res, idx);
      if (pathname === "/preview" || pathname === "/preview/") {
        if (await appUp()) return proxyToApp(req, res, "/", search);
        return send(res, 200, PREVIEW_HINT, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
      }
    }
  }

  // ② 其余(不存在的前端资源 / API / 写请求)→ 反代到访客后端(约定端口 8000)
  if (await appUp()) return proxyToApp(req, res, "/" + rel, search);
  return notFound(res);
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  const pathname = url.pathname;

  // 预览(含访客后端反代)支持任意方法(GET/HEAD/POST/PUT/DELETE…),先于只读校验
  if (pathname === "/preview" || pathname.startsWith("/preview/")) return servePreview(req, res, pathname, url.search);

  // 「改模型」:忽略请求体,强制网关默认模型(见 serveForcedModel)
  if (req.method === "POST" && /^\/api\/session\/[^/]+\/model$/.test(pathname))
    return serveForcedModel(req, res, pathname, url.search);

  // 会话历史:截断为最近 N 条、不再向更早翻页(见 serveCappedMessages)
  if (req.method === "GET" && /^\/api\/session\/[^/]+\/message$/.test(pathname))
    return serveCappedMessages(req, res, pathname, url.search);

  if (req.method !== "GET" && req.method !== "HEAD") return send(res, 405, "method not allowed");
  if (pathname === "/__hub") return serveHub(req, res);
  if (pathname === "/__shell") return serveShell(req, res);
  if (pathname === "/__config") return serveSanitizedConfig(res, url.search);
  if (pathname === "/__provider") return serveSanitizedProvider(res, url.search);
  if (pathname === "/__model") return serveSanitizedModel(res, url.search);
  if (pathname === "/__model-default") return serveSanitizedModelDefault(res, url.search);
  if (pathname === "/__preview-health") return send(res, 200, "ok", { "Content-Type": "text/plain" });
  if (pathname === "/sw.js") return serveSw(req, res);
  // 裁剪版 UI 静态资源(_assets/assets/icons 及根级文件)
  return serveDistFile(req, res, pathname);
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`[sandbox-helper] listening on :${PORT} (workspace=${WORKSPACE}, session=${SESSION_ID})`);
});
