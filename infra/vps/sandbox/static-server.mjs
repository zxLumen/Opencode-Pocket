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
import { stat, readFile, mkdir, writeFile, rename } from "node:fs/promises";
import { createReadStream } from "node:fs";
import { extname, join, resolve, sep } from "node:path";
import { connect as netConnect } from "node:net";
import { inflateSync, brotliDecompressSync } from "node:zlib";
import { createHash } from "node:crypto";

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

// =====================================================================
// 直播投票 + 自动接棒
//   观众在 YouTube 直播聊天(弹幕)提意见 → 相同/相近的自动合并计票 →
//   会话本轮跑完(session.idle)自动把**票数最高**的意见发给模型继续 →
//   发送后**清零重来**,并把已发送的记入「已实行」列表。
//   详细说明见 docs/vps-sandbox.md「观众投票 → 自动接棒」。
//   全部用 node 内置模块;状态持久化到家目录卷(部署/重启不丢)。
// =====================================================================
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const LIVE_ENABLED = process.env.PLAYGROUND_LIVE !== "0";
const MIN_VOTES = Number(process.env.PLAYGROUND_MIN_VOTES || 2);
const COOLDOWN_MS = Number(process.env.PLAYGROUND_COOLDOWN_SEC || 20) * 1000;
const MAX_ROUNDS = Number(process.env.PLAYGROUND_MAX_ROUNDS || 0); // 0 = 不限
const MERGE_ENABLED = process.env.PLAYGROUND_MERGE !== "0";
const MERGE_INTERVAL_MS = Number(process.env.PLAYGROUND_MERGE_INTERVAL_MS || 30000);
const AUTO_DIRECT_DEFAULT = process.env.PLAYGROUND_AUTODIRECT !== "0";
const ADMIN_TOKEN = process.env.PLAYGROUND_ADMIN_TOKEN || "";
const MAX_OPINION_LEN = Number(process.env.PLAYGROUND_MAX_OPINION_LEN || 120);
const USER_COOLDOWN_MS = Number(process.env.PLAYGROUND_USER_COOLDOWN_MS || 3000);
const GATEWAY_URL = (process.env.PLAYGROUND_GATEWAY_URL || "http://app:3000/api/ai/v1").replace(/\/+$/, "");
const GATEWAY_MODEL = process.env.PLAYGROUND_GATEWAY_MODEL || "gateway-default";
const GATEWAY_TOKEN = process.env.ZX_AI_APP_TOKEN || "";
const YT_API_KEY = process.env.YT_API_KEY || "";
const YT_VIDEO_ID = (process.env.YT_VIDEO_ID || "").trim();
const YT_POLL_MS = Number(process.env.YT_POLL_MS || 0);
// 弹幕源:youtube | bilibili | off(默认按已配置的凭据自动选)
const BILI_ROOM_ID = String(process.env.BILI_ROOM_ID || "").trim();
const CHAT_SOURCE = String(
  process.env.CHAT_SOURCE || (YT_API_KEY && YT_VIDEO_ID ? "youtube" : BILI_ROOM_ID ? "bilibili" : "off"),
).toLowerCase();
const BOARD_FILE = process.env.SANDBOX_BOARD_FILE || "/srv/board.html";
const STATE_DIR = process.env.PLAYGROUND_STATE_DIR || join(process.env.HOME || "/home/opencode", ".local/state/sandbox");
const STATE_FILE = join(STATE_DIR, "live.json");

const chatEnabled = CHAT_SOURCE === "youtube" ? Boolean(YT_API_KEY && YT_VIDEO_ID) : CHAT_SOURCE === "bilibili" ? Boolean(BILI_ROOM_ID) : false;
let live = {
  round: 1,
  autoDirect: AUTO_DIRECT_DEFAULT,
  options: [], // { id, text, norm, votes, voters:[channelId], createdAt }
  executed: [], // { round, text, votes, at, status: running|done|failed }
  lastSentText: null,
  lastInjectAt: 0,
  currentRun: null,
  session: "unknown",
  chat: { source: CHAT_SOURCE, enabled: chatEnabled, connected: false, chatId: null, videoId: YT_VIDEO_ID || null, detail: CHAT_SOURCE === "bilibili" ? (BILI_ROOM_ID || null) : (YT_VIDEO_ID || null), lastAt: 0, error: null },
};

async function loadLive() {
  try {
    const d = JSON.parse(await readFile(STATE_FILE, "utf8"));
    if (d && typeof d === "object") {
      live.round = Number(d.round) || 1;
      if (typeof d.autoDirect === "boolean") live.autoDirect = d.autoDirect;
      live.options = Array.isArray(d.options) ? d.options.filter((o) => o && o.text && o.norm) : [];
      live.executed = Array.isArray(d.executed) ? d.executed : [];
      live.lastSentText = d.lastSentText || null;
      live.lastInjectAt = Number(d.lastInjectAt) || 0;
      live.currentRun = [...live.executed].reverse().find((e) => e && e.status === "running") || null;
    }
  } catch {}
}
let saveTimer = null;
function saveLive() {
  if (saveTimer) return;
  saveTimer = setTimeout(async () => {
    saveTimer = null;
    try {
      await mkdir(STATE_DIR, { recursive: true });
      const tmp = STATE_FILE + ".tmp";
      const data = {
        round: live.round, autoDirect: live.autoDirect, options: live.options,
        executed: live.executed.slice(-200), lastSentText: live.lastSentText, lastInjectAt: live.lastInjectAt,
      };
      await writeFile(tmp, JSON.stringify(data));
      await rename(tmp, STATE_FILE);
    } catch (e) { console.error("[live] 状态保存失败:", e && e.message); }
  }, 500);
}

// ---------- 状态广播(SSE) ----------
const sseClients = new Set();
function publicState() {
  const options = [...live.options]
    .sort((a, b) => b.votes - a.votes || a.createdAt - b.createdAt)
    .map((o, i) => ({ rank: i + 1, id: o.id, text: o.text, votes: o.votes }));
  const leader = options.length ? { text: options[0].text, votes: options[0].votes } : null;
  return {
    round: live.round,
    autoDirect: live.autoDirect,
    session: live.session,
    minVotes: MIN_VOTES,
    cooldownSec: Math.round(COOLDOWN_MS / 1000),
    maxRounds: MAX_ROUNDS,
    merge: MERGE_ENABLED,
    chat: { source: live.chat.source, enabled: live.chat.enabled, connected: live.chat.connected, lastAt: live.chat.lastAt, error: live.chat.error, detail: live.chat.detail, videoId: live.chat.videoId },
    options,
    leader,
    executed: live.executed.slice(-40).reverse(),
    lastInjectAt: live.lastInjectAt,
  };
}
function broadcastLive() {
  const payload = "data: " + JSON.stringify(publicState()) + "\n\n";
  for (const res of sseClients) { try { res.write(payload); } catch {} }
}
function changed() { saveLive(); broadcastLive(); }

// ---------- 文本规范化 / 计票 ----------
function normText(s) {
  return String(s || "")
    .normalize("NFKC")
    .toLowerCase()
    .replace(/[\s\u3000]+/g, "")
    .replace(/[\p{P}\p{S}]/gu, "");
}
let idSeq = 0;
function newOptId() { idSeq += 1; return "o" + Date.now().toString(36) + idSeq.toString(36); }

function vote(opt, channelId) {
  if (channelId && opt.voters.includes(channelId)) return false;
  if (channelId) opt.voters.push(channelId);
  opt.votes += 1;
  changed();
  maybeInject(); // 会话空闲时,投票即可触发自动接棒(带冷却/最小票数护栏)
  return true;
}
function addOpinion(text, channelId) {
  text = String(text || "").trim();
  if (!text) return null;
  if (text.length > MAX_OPINION_LEN) text = text.slice(0, MAX_OPINION_LEN);
  const norm = normText(text);
  if (!norm) return null;
  channelId = channelId || "anon:" + Math.random().toString(36).slice(2, 8);
  let opt = live.options.find((o) => o.norm === norm);
  if (!opt) {
    opt = { id: newOptId(), text, norm, votes: 0, voters: [], createdAt: Date.now() };
    live.options.push(opt);
    markMergeDirty();
  }
  vote(opt, channelId);
  return opt;
}
function sortedOptions() {
  return [...live.options].sort((a, b) => b.votes - a.votes || a.createdAt - b.createdAt);
}
function handleChat(text, channelId) {
  const t = String(text || "").trim();
  if (!t) return;
  const m = t.match(/^#?(\d{1,2})$/) || t.match(/^\+(\d{1,2})$/) || t.match(/^(?:投票|vote)\s*#?(\d{1,2})$/i);
  if (m) {
    const opt = sortedOptions()[Number(m[1]) - 1];
    if (opt) vote(opt, channelId);
    return;
  }
  addOpinion(t, channelId);
}
const lastByUser = new Map();
function allowUser(channelId, now) {
  if (!channelId) return true;
  const prev = lastByUser.get(channelId) || 0;
  if (now - prev < USER_COOLDOWN_MS) return false;
  lastByUser.set(channelId, now);
  if (lastByUser.size > 5000) lastByUser.clear();
  return true;
}

// ---------- YouTube 直播聊天采集(官方 Data API v3,API key) ----------
const seenMessages = new Set();
function rememberSeen(id) {
  seenMessages.add(id);
  if (seenMessages.size > 8000) { const keep = [...seenMessages].slice(-2000); seenMessages.clear(); for (const k of keep) seenMessages.add(k); }
}
async function ytResolveChatId() {
  let vid = YT_VIDEO_ID;
  const um = vid.match(/[?&]v=([\w-]{6,})/);
  if (um) vid = um[1];
  const u = new URL("https://www.googleapis.com/youtube/v3/videos");
  u.searchParams.set("part", "liveStreamingDetails");
  u.searchParams.set("id", vid);
  u.searchParams.set("key", YT_API_KEY);
  const r = await fetch(u, { headers: { accept: "application/json" } });
  if (!r.ok) throw new Error("videos.list HTTP " + r.status);
  const d = await r.json();
  const item = d.items && d.items[0];
  const chatId = item && item.liveStreamingDetails && item.liveStreamingDetails.activeLiveChatId;
  if (!chatId) throw new Error("拿不到 activeLiveChatId(直播可能还没开始)");
  return chatId;
}
let ytToken = null, ytPrimed = false;
async function ytPollOnce() {
  const u = new URL("https://www.googleapis.com/youtube/v3/liveChatMessages");
  u.searchParams.set("liveChatId", live.chat.chatId);
  u.searchParams.set("part", "snippet,authorDetails");
  u.searchParams.set("maxResults", "200");
  u.searchParams.set("key", YT_API_KEY);
  if (ytToken) u.searchParams.set("pageToken", ytToken);
  const r = await fetch(u, { headers: { accept: "application/json" } });
  if (!r.ok) throw new Error("liveChatMessages HTTP " + r.status);
  const d = await r.json();
  ytToken = d.nextPageToken || ytToken;
  const items = Array.isArray(d.items) ? d.items : [];
  if (!ytPrimed) {
    // 首帧是历史消息:只记游标,不当作投票
    for (const it of items) if (it.id) rememberSeen(it.id);
    ytPrimed = true;
  } else {
    for (const it of items) {
      if (!it.id || seenMessages.has(it.id)) continue;
      rememberSeen(it.id);
      const sn = it.snippet || {};
      if (sn.type !== "textMessageEvent") continue;
      const ch = (it.authorDetails && it.authorDetails.channelId) || "";
      if (!allowUser(ch, Date.now())) continue;
      handleChat(sn.displayMessage, ch);
    }
  }
  live.chat.connected = true;
  live.chat.error = null;
  live.chat.lastAt = Date.now();
  return Number(d.pollingIntervalMillis) || 5000;
}
async function ytLoop() {
  if (!chatEnabled) { console.log("[live] 未配置 YouTube(YT_API_KEY/YT_VIDEO_ID),跳过弹幕采集"); return; }
  for (;;) {
    try { live.chat.chatId = await ytResolveChatId(); live.chat.error = null; break; }
    catch (e) { live.chat.error = String((e && e.message) || e); console.error("[live] 解析 liveChatId:", live.chat.error); await sleep(15000); }
  }
  console.log("[live] YouTube 直播聊天已连接:", live.chat.chatId);
  for (;;) {
    let delay = 5000;
    try { delay = await ytPollOnce(); }
    catch (e) { live.chat.error = String((e && e.message) || e); live.chat.connected = false; console.error("[live] 拉取弹幕:", live.chat.error); delay = 10000; }
    broadcastLive();
    await sleep(YT_POLL_MS || Math.min(10000, Math.max(2000, delay)));
  }
}

// ---------- AI 语义合并(把意思相近的意见并成一条,票数相加) ----------
let mergeDirty = false, mergeRunning = false;
function markMergeDirty() { if (MERGE_ENABLED) mergeDirty = true; }
async function aiMerge() {
  if (!MERGE_ENABLED || !GATEWAY_TOKEN || live.options.length < 2) return;
  const list = live.options.map((o) => ({ id: o.id, text: o.text }));
  const sys = "你是投票去重助手。输入是观众意见的 JSON 数组。请把语义相同或高度相近的意见合并成组," +
    "只输出 JSON 数组,每个元素是一组 id 字符串的数组(只放需要合并、且每组长度≥2)。不要任何解释。";
  let content;
  try {
    const r = await fetch(GATEWAY_URL + "/chat/completions", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer " + GATEWAY_TOKEN },
      body: JSON.stringify({ model: GATEWAY_MODEL, temperature: 0, messages: [{ role: "system", content: sys }, { role: "user", content: JSON.stringify(list) }] }),
    });
    if (!r.ok) throw new Error("HTTP " + r.status);
    const d = await r.json();
    content = d && d.choices && d.choices[0] && d.choices[0].message && d.choices[0].message.content;
  } catch (e) { console.error("[live] AI 合并调用失败:", (e && e.message) || e); return; }
  if (!content) return;
  let groups;
  try {
    const s = content.indexOf("["), e2 = content.lastIndexOf("]");
    if (s < 0 || e2 < s) return;
    groups = JSON.parse(content.slice(s, e2 + 1));
  } catch { return; }
  if (!Array.isArray(groups)) return;
  let merged = false;
  for (const g of groups) {
    if (!Array.isArray(g) || g.length < 2) continue;
    const ids = new Set(g);
    const opts = live.options.filter((o) => ids.has(o.id)).sort((a, b) => b.votes - a.votes);
    if (opts.length < 2) continue;
    const keep = opts[0];
    for (const o of opts.slice(1)) {
      keep.votes += o.votes;
      for (const v of o.voters) if (!keep.voters.includes(v)) keep.voters.push(v);
    }
    const drop = new Set(opts.slice(1).map((o) => o.id));
    live.options = live.options.filter((o) => !drop.has(o.id));
    merged = true;
  }
  if (merged) { console.log("[live] AI 合并完成,剩", live.options.length, "条"); changed(); maybeInject(); }
}
async function mergeLoop() {
  for (;;) {
    await sleep(MERGE_INTERVAL_MS);
    if (!mergeDirty || mergeRunning) continue;
    mergeDirty = false; mergeRunning = true;
    try { await aiMerge(); } catch (e) { console.error("[live] 合并异常:", (e && e.message) || e); }
    mergeRunning = false;
  }
}

// ---------- 自动接棒:会话跑完 → 把票王发给模型 → 清零 ----------
async function upstreamFetch(path, opts = {}) {
  const headers = { accept: "application/json", ...(UPSTREAM_AUTH ? { authorization: UPSTREAM_AUTH } : {}), ...(opts.headers || {}) };
  return fetch(UPSTREAM + path, { ...opts, headers });
}
function topOption() {
  const s = sortedOptions();
  return s.length ? s[0] : null;
}
function finishRun(kind) {
  const e = live.currentRun;
  if (e && e.status === "running") { e.status = kind; live.currentRun = null; changed(); }
}
async function injectTop(top) {
  if (live.injecting) return false;
  live.injecting = true;
  try {
    const text = "【观众投票 · 第 " + live.round + " 轮】" + top.text;
    try {
      const r = await upstreamFetch("/api/session/" + encodeURIComponent(SESSION_ID) + "/prompt", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ text }),
      });
      if (!r.ok) throw new Error("HTTP " + r.status);
    } catch (e) { console.error("[live] 注入失败:", (e && e.message) || e); return false; }
  } finally { live.injecting = false; }
  const entry = { round: live.round, text: top.text, votes: top.votes, at: Date.now(), status: "running" };
  live.executed.push(entry);
  if (live.executed.length > 200) live.executed = live.executed.slice(-200);
  live.currentRun = entry;
  live.lastSentText = top.text;
  live.lastInjectAt = entry.at;
  live.session = "running";
  live.round += 1;
  live.options = []; // 发送后清零重来
  console.log("[live] 已注入第", entry.round, "轮:", top.text);
  changed();
  return true;
}
function maybeInject() {
  if (!LIVE_ENABLED || !live.autoDirect) return;
  if (live.session !== "idle") return;
  if (MAX_ROUNDS > 0 && live.round > MAX_ROUNDS) return;
  if (Date.now() - live.lastInjectAt < COOLDOWN_MS) return;
  const top = topOption();
  if (!top || top.votes < MIN_VOTES) return;
  if (top.text === live.lastSentText) return;
  injectTop(top);
}
let finishedTimer = null;
function onFinishedEvent() {
  if (Date.now() - live.lastInjectAt < 2000) return; // 刚注入,忽略旧运行的尾随事件
  if (finishedTimer) clearTimeout(finishedTimer);
  finishedTimer = setTimeout(() => {
    finishedTimer = null;
    finishRun("done");
    if (live.session !== "idle") { live.session = "idle"; broadcastLive(); }
    maybeInject();
  }, 1000);
}
function onFailedEvent() {
  finishRun("failed");
  if (live.session !== "idle") { live.session = "idle"; broadcastLive(); }
}
function handleSessionEvent(ev) {
  const t = ev && ev.type;
  if (!t) return;
  const d = ev.data || {};
  const sid = d.sessionID || d.sessionId || d.session;
  if (sid && sid !== SESSION_ID) return;
  if (t === "session.execution.started" || t === "session.step.started") {
    if (live.session !== "running") { live.session = "running"; broadcastLive(); }
  } else if (t === "session.idle" || t === "session.execution.succeeded") {
    onFinishedEvent();
  } else if (t === "session.execution.failed" || t === "session.error") {
    onFailedEvent();
  }
}
async function sessionEventLoop() {
  for (;;) {
    try {
      const r = await fetch(UPSTREAM + "/api/event", {
        headers: { accept: "text/event-stream", ...(UPSTREAM_AUTH ? { authorization: UPSTREAM_AUTH } : {}) },
      });
      if (!r.ok || !r.body) throw new Error("event HTTP " + r.status);
      const reader = r.body.getReader();
      const dec = new TextDecoder();
      let buf = "";
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        let idx;
        while ((idx = buf.indexOf("\n\n")) >= 0) {
          const chunk = buf.slice(0, idx); buf = buf.slice(idx + 2);
          for (const line of chunk.split("\n")) {
            if (!line.startsWith("data:")) continue;
            const json = line.slice(5).trim();
            if (!json) continue;
            try { handleSessionEvent(JSON.parse(json)); } catch {}
          }
        }
      }
    } catch (e) { console.error("[live] 会话事件流断开:", (e && e.message) || e); }
    await sleep(3000);
  }
}
async function sessionPollLoop() {
  for (;;) {
    try {
      const r = await upstreamFetch("/api/session/active");
      if (r.ok) {
        const d = await r.json();
        const map = (d && d.data) || {};
        const running = Boolean(map[SESSION_ID]);
        const st = running ? "running" : "idle";
        if (st !== live.session) {
          const prev = live.session;
          live.session = st;
          broadcastLive();
          if (st === "idle" && prev === "running") onFinishedEvent();
        }
      }
    } catch {}
    await sleep(4000);
  }
}
// ---------- B 站直播弹幕(WebSocket 二进制协议;零依赖) ----------
// 匿名直连会被风控(-352):先取 buvid 指纹 + WBI 签名调 getDanmuInfo 拿 token/节点,再连 WS。
// 认证包(op=7,protover=3)→ 服务端 op=5 推送(可能 brotli/zlib 压缩)→ DANMU_MSG 取文本与 uid;每 30s op=2 心跳。
const BILI_API = process.env.BILI_API || "https://api.live.bilibili.com";
const BILI_WS_FALLBACK = process.env.BILI_WS_URL || "wss://broadcastlv.chat.bilibili.com/sub";
const BILI_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const BILI_HEADER = 16;
// WBI 签名混淆表(官方固定)
const BILI_MIXIN_TAB = [46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13,37,48,7,16,24,55,40,61,26,17,0,1,60,51,30,4,22,25,54,21,56,59,6,63,57,62,11,36,20,34,44,52];

function biliPacket(op, body) {
  const payload = body == null ? Buffer.alloc(0) : Buffer.from(body);
  const buf = Buffer.alloc(BILI_HEADER + payload.length);
  buf.writeUInt32BE(BILI_HEADER + payload.length, 0);
  buf.writeUInt16BE(BILI_HEADER, 4);
  buf.writeUInt16BE(1, 6); // protocol version 1(明文)
  buf.writeUInt32BE(op, 8);
  buf.writeUInt32BE(1, 12); // sequence
  payload.copy(buf, BILI_HEADER);
  return buf;
}
async function biliResolveRoom() {
  const r = await fetch(BILI_API + "/room/v1/Room/get_info?room_id=" + encodeURIComponent(BILI_ROOM_ID), {
    headers: { accept: "application/json", "user-agent": "Mozilla/5.0" },
  });
  if (!r.ok) throw new Error("room_info HTTP " + r.status);
  const d = await r.json();
  if (d.code !== 0 || !d.data || !d.data.room_id) throw new Error("room_info code " + d.code + " " + (d.msg || ""));
  return d.data.room_id;
}
function biliHandlePayload(buf) {
  let off = 0;
  while (off + BILI_HEADER <= buf.length) {
    const total = buf.readUInt32BE(off);
    const hlen = buf.readUInt16BE(off + 4);
    const ver = buf.readUInt16BE(off + 6);
    const op = buf.readUInt32BE(off + 8);
    if (total < hlen || off + total > buf.length) break;
    const payload = buf.subarray(off + hlen, off + total);
    off += total;
    if (ver === 2 || ver === 3) {
      let dec;
      try { dec = ver === 2 ? inflateSync(payload) : brotliDecompressSync(payload); } catch { continue; }
      biliHandlePayload(dec);
      continue;
    }
    if (op !== 5) continue;
    const text = payload.toString("utf8");
    if (!text) continue;
    let obj;
    try { obj = JSON.parse(text); } catch { continue; }
    if (!obj || typeof obj.cmd !== "string" || obj.cmd.indexOf("DANMU_MSG") !== 0) continue;
    const info = obj.info || [];
    const msg = info[1];
    const uid = (info[2] && info[2][0]) || 0;
    if (typeof msg !== "string" || !msg) continue;
    live.chat.lastAt = Date.now();
    const ch = uid ? "bili:" + uid : "";
    if (!allowUser(ch, Date.now())) continue;
    handleChat(msg, ch);
  }
}
function biliMixinKey(orig) { return BILI_MIXIN_TAB.map((i) => orig[i]).join("").slice(0, 32); }
function biliEncWbi(params, imgKey, subKey) {
  const mixin = biliMixinKey(imgKey + subKey);
  const wts = Math.round(Date.now() / 1000);
  const all = { ...params, wts };
  const query = Object.keys(all).sort()
    .map((k) => encodeURIComponent(k) + "=" + encodeURIComponent(String(all[k]).replace(/[!'()*]/g, "")))
    .join("&");
  return query + "&w_rid=" + createHash("md5").update(query + mixin).digest("hex");
}
let biliFp = null; // { b3, b4, imgKey, subKey, at }
async function biliFingerprint(force) {
  if (biliFp && !force && Date.now() - biliFp.at < 3600e3) return biliFp;
  const spi = await (await fetch("https://api.bilibili.com/x/frontend/finger/spi", { headers: { "user-agent": BILI_UA } })).json();
  const b3 = (spi && spi.data && spi.data.b_3) || "";
  const b4 = (spi && spi.data && spi.data.b_4) || "";
  const nav = await (await fetch("https://api.bilibili.com/x/web-interface/nav", {
    headers: { "user-agent": BILI_UA, referer: "https://www.bilibili.com/", ...(b3 ? { cookie: "buvid3=" + b3 } : {}) },
  })).json();
  const imgKey = ((((nav && nav.data && nav.data.wbi_img && nav.data.wbi_img.img_url) || "").split("/").pop()) || "").split(".")[0];
  const subKey = ((((nav && nav.data && nav.data.wbi_img && nav.data.wbi_img.sub_url) || "").split("/").pop()) || "").split(".")[0];
  if (!imgKey || !subKey) throw new Error("拿不到 WBI 密钥(nav code " + (nav && nav.code) + ")");
  biliFp = { b3, b4, imgKey, subKey, at: Date.now() };
  return biliFp;
}
async function biliGetDanmuInfo(realRoom) {
  const fp = await biliFingerprint(false);
  const qs = biliEncWbi({ id: String(realRoom), type: 0 }, fp.imgKey, fp.subKey);
  const r = await fetch(BILI_API + "/xlive/web-room/v1/index/getDanmuInfo?" + qs, {
    headers: { "user-agent": BILI_UA, referer: "https://live.bilibili.com/", ...(fp.b3 ? { cookie: "buvid3=" + fp.b3 + "; buvid4=" + fp.b4 } : {}) },
  });
  const d = await r.json();
  const info = d && d.data;
  if (!d || d.code !== 0 || !info || !info.token || !Array.isArray(info.host_list) || !info.host_list.length) {
    biliFingerprint(true).catch(() => {}); // 下次刷新指纹
    throw new Error("getDanmuInfo code " + (d && d.code) + " " + ((d && (d.message || d.msg)) || ""));
  }
  return { token: info.token, host: info.host_list[0] };
}
function biliSession(host, token, roomid) {
  return new Promise((resolve) => {
    const url = host ? "wss://" + host.host + ":" + host.wss_port + "/sub" : BILI_WS_FALLBACK;
    const headers = { Origin: "https://live.bilibili.com", "User-Agent": BILI_UA, ...(biliFp && biliFp.b3 ? { Cookie: "buvid3=" + biliFp.b3 } : {}) };
    let ws;
    try { ws = new WebSocket(url, { headers }); } catch { try { ws = new WebSocket(url); } catch { return resolve(); } }
    try { ws.binaryType = "arraybuffer"; } catch {}
    let hb = null, settled = false;
    const done = () => { if (settled) return; settled = true; if (hb) clearInterval(hb); try { ws.close(); } catch {} resolve(); };
    ws.addEventListener("open", () => {
      const auth = JSON.stringify({ uid: 0, roomid: Number(roomid), protover: 3, platform: "web", type: 2, key: token || "" });
      try { ws.send(biliPacket(7, auth)); } catch { return done(); }
      hb = setInterval(() => { try { ws.send(biliPacket(2, null)); } catch {} }, 30000);
    });
    ws.addEventListener("message", (ev) => {
      const d = ev.data;
      const p = d instanceof ArrayBuffer ? Promise.resolve(Buffer.from(d))
        : (d && typeof d.arrayBuffer === "function" ? d.arrayBuffer().then((b) => Buffer.from(b)) : Promise.resolve(null));
      p.then((buf) => {
        if (!buf) return;
        if (!live.chat.connected) { live.chat.connected = true; live.chat.error = null; broadcastLive(); }
        try { biliHandlePayload(buf); } catch (e) { console.error("[live] B站弹幕解析:", (e && e.message) || e); }
      }).catch(() => {});
    });
    ws.addEventListener("error", () => {});
    ws.addEventListener("close", () => done());
  });
}
async function biliLoop() {
  if (!BILI_ROOM_ID) { console.log("[live] 未配置 BILI_ROOM_ID,跳过 B 站弹幕采集"); return; }
  let realRoom;
  for (;;) {
    try { realRoom = await biliResolveRoom(); live.chat.detail = String(realRoom); live.chat.error = null; break; }
    catch (e) { live.chat.error = String((e && e.message) || e); console.error("[live] B站房间信息:", live.chat.error); await sleep(10000); }
  }
  console.log("[live] B 站弹幕:房间", BILI_ROOM_ID, "→ 真实 room", realRoom);
  for (;;) {
    let info = null;
    try { info = await biliGetDanmuInfo(realRoom); }
    catch (e) { live.chat.error = String((e && e.message) || e); live.chat.connected = false; console.error("[live] B站 getDanmuInfo:", live.chat.error); broadcastLive(); await sleep(10000); continue; }
    try { await biliSession(info.host, info.token, realRoom); }
    catch (e) { live.chat.error = String((e && e.message) || e); console.error("[live] B站弹幕断开:", live.chat.error); }
    live.chat.connected = false; broadcastLive();
    await sleep(5000);
  }
}

function startLive() {
  if (!LIVE_ENABLED) { console.log("[live] 已禁用(PLAYGROUND_LIVE=0)"); return; }
  if (CHAT_SOURCE === "bilibili") biliLoop();
  else if (CHAT_SOURCE === "youtube") ytLoop();
  else console.log("[live] 未配置弹幕源(YT_API_KEY/YT_VIDEO_ID 或 BILI_ROOM_ID)");
  mergeLoop(); sessionEventLoop(); sessionPollLoop();
  console.log("[live] 直播投票已启动: 轮次=", live.round, "自动接棒=", live.autoDirect, "最小票数=", MIN_VOTES, "自动合并=", MERGE_ENABLED);
  setTimeout(maybeInject, 5000); // 重启后若已有票且会话空闲,补接一轮
}

// ---------- 榜单页 / 状态端点 / 管理 ----------
async function serveBoard(req, res) {
  let html;
  try { html = await readFile(BOARD_FILE, "utf8"); }
  catch { return send(res, 500, "board unavailable", { "Content-Type": "text/plain; charset=utf-8" }); }
  res.writeHead(200, { ...baseHeaders, "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
  res.end(req.method === "HEAD" ? undefined : html);
}
function serveLiveEvents(req, res) {
  res.writeHead(200, {
    ...baseHeaders,
    "Content-Type": "text/event-stream; charset=utf-8",
    "Cache-Control": "no-cache, no-transform",
    Connection: "keep-alive",
    "X-Accel-Buffering": "no",
  });
  res.write(": connected\n\n");
  res.write("data: " + JSON.stringify(publicState()) + "\n\n");
  sseClients.add(res);
  const hb = setInterval(() => { try { res.write(": hb\n\n"); } catch {} }, 15000);
  req.on("close", () => { clearInterval(hb); sseClients.delete(res); });
}
function readBody(req, limit = 1e6) {
  return new Promise((resolve) => {
    let data = "", n = 0;
    req.on("data", (c) => { n += c.length; if (n > limit) { req.destroy(); return; } data += c; });
    req.on("end", () => resolve(data));
    req.on("error", () => resolve(data));
  });
}
async function handleAdmin(req, res) {
  if (!ADMIN_TOKEN) return send(res, 403, "admin disabled", { "Content-Type": "text/plain; charset=utf-8" });
  const url = new URL(req.url, "http://localhost");
  const token = req.headers["x-admin-token"] || url.searchParams.get("token") || "";
  if (token !== ADMIN_TOKEN) return send(res, 403, "forbidden", { "Content-Type": "text/plain; charset=utf-8" });
  let body = {};
  try { body = JSON.parse((await readBody(req)) || "{}"); } catch {}
  const action = body.action;
  if (action === "start") live.autoDirect = true;
  else if (action === "pause") live.autoDirect = false;
  else if (action === "reset") live.options = [];
  else if (action === "clear-executed") live.executed = [];
  else if (action === "add") addOpinion(String(body.text || ""), "admin");
  else if (action === "send") { const t = topOption(); if (t) await injectTop(t); }
  else return json(res, { ok: false, error: "unknown action" });
  changed();
  return json(res, { ok: true, state: publicState() });
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  const pathname = url.pathname;

  // 预览(含访客后端反代)支持任意方法(GET/HEAD/POST/PUT/DELETE…),先于只读校验
  if (pathname === "/preview" || pathname.startsWith("/preview/")) return servePreview(req, res, pathname, url.search);

  // 直播投票:榜单页 + 状态(SSE) + 管理(POST,需 token);读写都在只读校验之前
  if (pathname === "/__board") return serveBoard(req, res);
  if (pathname === "/__lb/state") return json(res, publicState());
  if (pathname === "/__lb/events") return serveLiveEvents(req, res);
  if (pathname === "/__lb/admin") {
    if (req.method !== "POST") return send(res, 405, "method not allowed");
    return handleAdmin(req, res);
  }

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

// 读回上次的投票状态,再启动直播投票 / 自动接棒的后台循环。
loadLive().then(startLive).catch((e) => console.error("[live] 初始化失败:", (e && e.message) || e));
