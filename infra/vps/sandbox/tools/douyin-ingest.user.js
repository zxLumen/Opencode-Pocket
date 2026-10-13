// ==UserScript==
// @name         抖音弹幕 → 沙盒投票 (ingest)
// @namespace    zxlumen-sandbox
// @version      1.0
// @description  把抖音直播间的弹幕转发到沙盒 /__lb/ingest,进入观众投票池(与 B 站合并计票)
// @match        https://live.douyin.com/*
// @grant        GM_xmlhttpRequest
// @connect      *
// @run-at       document-idle
// ==/UserScript==
(function () {
  "use strict";

  // ===================== 配置(必填) =====================
  const INGEST_URL = "https://code-sandbox.zxlumen.cn/__lb/ingest";
  const TOKEN = "在这里填 PLAYGROUND_INGEST_TOKEN";   // ← 填服务器 .env 里的令牌
  const PLATFORM = "douyin";
  // 抖音网页弹幕选择器(抖音改版时按需调整;可用浏览器 F12 在弹幕上右键「检查」核对)
  const ITEM_SELECTOR = '[class*="webcast-chatroom___item"]';
  const TEXT_SELECTOR = '[class*="webcast-chatroom___content"]';
  const NAME_SELECTOR = '[class*="nickname"], [class*="___name"]';
  const MAX_LEN = 200;   // 超长忽略
  // =====================================================

  const seen = new WeakSet();
  let sent = 0;
  const log = (...a) => { try { console.log("[dy→沙盒]", ...a); } catch (e) {} };

  if (/填/.test(TOKEN)) log("⚠️ 请先在脚本里填 TOKEN");

  function send(text, user) {
    text = String(text || "").replace(/\s+/g, " ").trim();
    if (!text || text.length > MAX_LEN) return;
    GM_xmlhttpRequest({
      method: "POST",
      url: INGEST_URL,
      headers: { "content-type": "application/json", "x-ingest-token": TOKEN },
      data: JSON.stringify({ platform: PLATFORM, user: String(user || ""), text: text }),
      onload: (r) => { if (r.status === 200) { sent++; } else { log("上报失败", r.status, text); } },
      onerror: () => log("上报网络错误"),
    });
  }

  function handleItem(el) {
    if (!el || seen.has(el)) return;
    seen.add(el);
    const t = el.querySelector(TEXT_SELECTOR) || el;
    const n = el.querySelector(NAME_SELECTOR);
    send(t.textContent, n ? n.textContent : "");
  }
  function handleAdded(node) {
    if (!node || node.nodeType !== 1) return;
    if (node.matches && node.matches(ITEM_SELECTOR)) handleItem(node);
    if (node.querySelectorAll) node.querySelectorAll(ITEM_SELECTOR).forEach(handleItem);
  }

  // 首次:把页面上已有的(历史)弹幕标记为已见,不转发;之后只转发新增
  document.querySelectorAll(ITEM_SELECTOR).forEach((el) => seen.add(el));

  new MutationObserver((muts) => {
    for (const m of muts) for (const n of m.addedNodes) handleAdded(n);
  }).observe(document.documentElement, { childList: true, subtree: true });

  log("已启动。选择器:", ITEM_SELECTOR, "→", INGEST_URL);
})();
