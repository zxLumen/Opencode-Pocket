// ==UserScript==
// @name         抖音弹幕 → 沙盒投票 (ingest v2)
// @namespace    zxlumen-sandbox
// @version      2.0
// @description  抖音直播弹幕转发到沙盒 /__lb/ingest;并防页面闲置暂停(可见性覆盖+定时伪活动+自动点掉「还在看吗」)
// @match        https://live.douyin.com/*
// @grant        GM_xmlhttpRequest
// @connect      code-sandbox.zxlumen.cn
// @run-at       document-start
// ==/UserScript==
(function () {
  "use strict";

  // ===================== 配置(必填) =====================
  const INGEST_URL = "https://code-sandbox.zxlumen.cn/__lb/ingest";
  const TOKEN = "在这里填 PLAYGROUND_INGEST_TOKEN";   // ← 填服务器 .env 里的令牌
  const PLATFORM = "douyin";
  const ITEM_SELECTOR = '[class*="webcast-chatroom___item"]';
  const TEXT_SELECTOR = '[class*="___content"]';
  const NAME_SELECTOR = '[class*="nickname"], [class*="___name"]';
  const MAX_LEN = 120;   // 超长忽略
  const DEBUG = true;
  // =====================================================

  // ---------- 1) 防闲置暂停:在【页面上下文】注入补丁 ----------
  // 抖音网页版长时间无交互会暂停并提示「还在看吗」。这里:覆盖 visibility 状态、
  // 拦掉 visibilitychange(切后台就暂停的逻辑)、定时伪活动 + 恢复视频 + 自动点掉提示框。
  const PATCH = `(function(){
    try {
      ['hidden','webkitHidden'].forEach(function(k){ try{ Object.defineProperty(document,k,{configurable:true,get:function(){return false;}}); }catch(e){} });
      ['visibilityState','webkitVisibilityState'].forEach(function(k){ try{ Object.defineProperty(document,k,{configurable:true,get:function(){return 'visible';}}); }catch(e){} });
    } catch(e){}
    ['visibilitychange','webkitvisibilitychange'].forEach(function(t){
      window.addEventListener(t, function(e){ e.stopImmediatePropagation(); }, true);
      document.addEventListener(t, function(e){ e.stopImmediatePropagation(); }, true);
    });
    setInterval(function(){
      try { var v=document.querySelector('video'); if(v && v.paused){ var p=v.play(); if(p && p.catch)p.catch(function(){}); } } catch(e){}
      try { window.dispatchEvent(new MouseEvent('mousemove',{bubbles:true,clientX:3,clientY:3})); window.dispatchEvent(new Event('scroll',{bubbles:true})); } catch(e){}
      try {
        var els=document.querySelectorAll('button,[role=button],a');
        for(var i=0;i<els.length;i++){
          var tx=(els[i].textContent||'').replace(/\\s+/g,'');
          if(/继续观看|继续播放|继续收看|我在看|确定继续|仍在观看/.test(tx)){ els[i].click(); break; }
        }
      } catch(e){}
    }, 30000);
  })();`;
  try {
    const sc = document.createElement("script");
    sc.textContent = PATCH;
    (document.head || document.documentElement).appendChild(sc);
    sc.remove();
  } catch (e) {}

  // ---------- 2) 采集弹幕并上报 ----------
  const seen = new WeakSet();
  let sent = 0, failed = 0;
  const log = (...a) => { try { console.log("[dy→沙盒]", ...a); } catch (e) {} };
  if (/填/.test(TOKEN)) log("⚠️ 请先在脚本里填 TOKEN");

  /** 过滤系统/公告/无意义消息 */
  function isJunk(text) {
    if (!text) return true;
    const t = text.trim();
    if (!t || t.length > MAX_LEN) return true;
    if (/严禁|欢迎来到直播间|直播间管理|系统提示|请勿|禁止发布|文明直播|理性消费/.test(t)) return true;
    try { if (/^[\p{P}\p{S}\s]+$/u.test(t)) return true; } catch (e) {} // 纯符号/表情
    return false;
  }

  function payloadOf(text, user) {
    return JSON.stringify({ platform: PLATFORM, user: String(user || ""), text: String(text || "").trim() });
  }
  async function send(text, user) {
    const body = payloadOf(text, user);
    try {
      const r = await fetch(INGEST_URL, { method: "POST", mode: "cors", headers: { "content-type": "application/json", "x-ingest-token": TOKEN }, body });
      if (r.ok) { sent++; if (DEBUG) log("✅", text); return; }
      log("⚠️ fetch HTTP", r.status);
    } catch (e) { log("⚠️ fetch 失败:", (e && e.message) || e, "→ GM"); }
    try {
      GM_xmlhttpRequest({
        method: "POST", url: INGEST_URL,
        headers: { "content-type": "application/json", "x-ingest-token": TOKEN },
        data: body,
        onload: (r) => { if (r.status === 200) sent++; else { failed++; log("❌ GM HTTP", r.status, text); } },
        onerror: (r) => { failed++; log("❌ GM 网络错误:", (r && (r.error || r.statusText)) || "unknown"); },
      });
    } catch (e) { log("❌ GM 不可用:", (e && e.message) || e); }
  }

  function handleItem(el) {
    if (!el || seen.has(el)) return;
    seen.add(el);
    const t = el.querySelector(TEXT_SELECTOR) || el;
    const n = el.querySelector(NAME_SELECTOR);
    const text = (t.textContent || "").trim();
    if (isJunk(text)) return;
    send(text, n ? n.textContent : "");
  }
  function handleAdded(node) {
    if (!node || node.nodeType !== 1) return;
    if (node.matches && node.matches(ITEM_SELECTOR)) handleItem(node);
    if (node.querySelectorAll) node.querySelectorAll(ITEM_SELECTOR).forEach(handleItem);
  }

  document.querySelectorAll(ITEM_SELECTOR).forEach((el) => seen.add(el)); // 历史不转发

  new MutationObserver((muts) => { for (const m of muts) for (const n of m.addedNodes) handleAdded(n); })
    .observe(document.documentElement, { childList: true, subtree: true });

  log("已启动(v2)。选择器:", ITEM_SELECTOR, "→", INGEST_URL);
  setInterval(() => log("统计: 已发", sent, "失败", failed), 60000);
})();
