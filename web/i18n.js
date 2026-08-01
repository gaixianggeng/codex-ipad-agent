/* Bilingual controller for the Mimi Remote marketing site.
   - Text nodes:   [data-i18n]        -> innerHTML from dict
   - Alt text:     [data-i18n-alt]    -> img.alt
   - Aria labels:  [data-i18n-label]  -> aria-label
   - Screenshots:  [data-shot="name"] -> ./assets/name-<lang>.png
   Default language follows the browser; the choice is remembered. */
(function () {
  "use strict";

  var STORAGE_KEY = "mimi-lang";

  var DICT = {
    en: {
      "skip": "Skip to main content",
      "nav.features": "Features",
      "nav.cta": "Get early access",

      "hero.eyebrow": "Coding agents, on the go",
      "hero.title": "Your agents.<br>Within reach.",
      "hero.lede": "Run Codex and Claude Code from iPad, iPhone, or Mac—without giving up the terminal at home.",
      "hero.cta1": "Get early access",
      "hero.cta2": "View on GitHub",

      "features.title": "Built to feel local, everywhere.",
      "features.fast.word": "Fast.",
      "features.fast.note": "Local-first execution on your own Mac. Responses arrive without a cloud round-trip.",
      "features.stable.word": "Stable.",
      "features.stable.note": "Connections recover on their own. Queued messages and status stay intact across drops.",
      "features.multi.word": "Multi‑device.",
      "features.multi.note": "iPad, iPhone, and Mac share one workflow—pick up a session wherever you are.",
      "features.native.word": "Native for iPad.",
      "features.native.note": "Designed for touch, the sidebar, and a wide-screen workspace—not a shrunk-down desktop page.",

      "runtimes.title": "One client. Two runtimes.",
      "runtimes.lede": "Mimi Remote talks to the agents you already run. Your Mac keeps the session alive; every device is just a window onto it.",
      "runtimes.chainLabel": "Codex and Claude Code both connect through Mac agentd.",

      "details.title": "The details, from the real app.",
      "details.d1.head": "Recover without losing the thread.",
      "details.d1.body": "When the link drops, nothing is lost. Unsent instructions wait in a local queue, saved on the device, and re-send the moment the connection returns.",
      "details.d2.head": "Built around iPad.",
      "details.d2.body": "A real sidebar, not a hamburger afterthought. Sessions and workspaces sit side by side, with in-progress and recent history always one glance away.",
      "details.d3.head": "Every workspace gets a face.",
      "details.d3.body": "Personalized icons make projects recognizable at a glance, and a Codex or Claude Code session is always one tap away.",

      "footer.eyebrow": "Get early access",
      "footer.title": "Take your coding agents with you.",
      "footer.cta1": "Get early access",
      "footer.cta2": "View on GitHub",
      "footer.docs": "Docs",
      "footer.privacy": "Privacy",
      "footer.fine": "An open-source client for Codex and Claude Code.",

      "alt.ipadWorkspace": "Mimi Remote's workspace on iPad, with the session and workspace sidebar beside running projects and recent conversations.",
      "alt.iphoneWorkspace": "The same Mimi Remote workspace on iPhone, in a single column.",
      "alt.cropQueue": "A queue reading 2 items to send, saved on this device, with one item marked last send interrupted before confirmation.",
      "alt.cropSidebar": "The iPad sidebar listing session and workspace, an in-progress task, and recent history.",
      "alt.cropFaces": "Two projects with personalized character icons, above quick actions to create a new Codex or Claude Code session."
    },
    zh: {
      "skip": "跳到主要内容",
      "nav.features": "特性",
      "nav.cta": "抢先体验",

      "hero.eyebrow": "随身携带的编码 Agent",
      "hero.title": "你的 Agent，<br>触手可及。",
      "hero.lede": "在 iPad、iPhone 或 Mac 上运行 Codex 与 Claude Code——同时保留家里那台终端。",
      "hero.cta1": "抢先体验",
      "hero.cta2": "在 GitHub 查看",

      "features.title": "在哪都像在本地。",
      "features.fast.word": "快。",
      "features.fast.note": "在你自己的 Mac 上本地优先执行，响应无需绕行云端。",
      "features.stable.word": "稳。",
      "features.stable.note": "断线自动恢复，待发送消息与状态在掉线后依然完整。",
      "features.multi.word": "多设备。",
      "features.multi.note": "iPad、iPhone、Mac 共用一套工作流——随时接着上一段会话。",
      "features.native.word": "为 iPad 而生。",
      "features.native.note": "为触控、侧栏与宽屏工作区专门设计——不是缩小版的桌面页面。",

      "runtimes.title": "一个客户端，两套运行时。",
      "runtimes.lede": "Mimi Remote 直连你已经在用的 Agent。会话由你的 Mac 保活，每台设备只是它的一扇窗。",
      "runtimes.chainLabel": "Codex 和 Claude Code 都通过 Mac agentd 连接。",

      "details.title": "细节，来自真实的 App。",
      "details.d1.head": "断线，也不丢上下文。",
      "details.d1.body": "链路中断时什么都不会丢。未发送的指令留在本地队列、保存在设备上，一旦连接恢复立即补发。",
      "details.d2.head": "围绕 iPad 打造。",
      "details.d2.body": "真正的侧栏，而不是塞进汉堡菜单。会话与工作区并列，进行中和最近历史一眼可见。",
      "details.d3.head": "每个工作区都有一张脸。",
      "details.d3.body": "个性化图标让项目一眼可辨，新建 Codex 或 Claude Code 会话永远只差一次点按。",

      "footer.eyebrow": "抢先体验",
      "footer.title": "把你的编码 Agent 带在身边。",
      "footer.cta1": "抢先体验",
      "footer.cta2": "在 GitHub 查看",
      "footer.docs": "文档",
      "footer.privacy": "隐私",
      "footer.fine": "一个面向 Codex 与 Claude Code 的开源客户端。",

      "alt.ipadWorkspace": "Mimi Remote 在 iPad 上的工作区，侧栏的会话与工作区旁是运行中的项目和最近会话。",
      "alt.iphoneWorkspace": "Mimi Remote 在 iPhone 上，以单列呈现同一工作区。",
      "alt.cropQueue": "一个待发送队列：2 条待发送、已保存在本设备，其中一条标记为上次发送在确认前中断。",
      "alt.cropSidebar": "iPad 侧栏，列出会话与工作区、一个进行中的任务和最近历史。",
      "alt.cropFaces": "两个带有个性化角色图标的项目，下方是新建 Codex 或 Claude Code 会话的快捷操作。"
    }
  };

  var LANG_LABEL = { en: "EN", zh: "中文" };
  var HTML_LANG = { en: "en", zh: "zh-Hans" };
  var SWITCH_ARIA = { en: "Switch to Chinese", zh: "切换到英文" };

  function detectLang() {
    var saved = null;
    try { saved = localStorage.getItem(STORAGE_KEY); } catch (e) {}
    if (saved === "en" || saved === "zh") return saved;
    var navLangs = navigator.languages || [navigator.language || "en"];
    for (var i = 0; i < navLangs.length; i++) {
      if (/^zh\b/i.test(navLangs[i])) return "zh";
      if (/^en\b/i.test(navLangs[i])) return "en";
    }
    return "en";
  }

  function apply(lang) {
    var dict = DICT[lang] || DICT.en;

    document.documentElement.setAttribute("lang", HTML_LANG[lang]);
    document.documentElement.setAttribute("data-lang", lang);

    document.querySelectorAll("[data-i18n]").forEach(function (el) {
      var v = dict[el.getAttribute("data-i18n")];
      if (v != null) el.innerHTML = v;
    });
    document.querySelectorAll("[data-i18n-alt]").forEach(function (el) {
      var v = dict[el.getAttribute("data-i18n-alt")];
      if (v != null) el.setAttribute("alt", v);
    });
    document.querySelectorAll("[data-i18n-label]").forEach(function (el) {
      var v = dict[el.getAttribute("data-i18n-label")];
      if (v != null) el.setAttribute("aria-label", v);
    });
    document.querySelectorAll("[data-shot]").forEach(function (img) {
      img.setAttribute("src", "./assets/" + img.getAttribute("data-shot") + "-" + lang + ".png");
    });

    var other = lang === "en" ? "zh" : "en";
    document.querySelectorAll("[data-lang-toggle]").forEach(function (btn) {
      btn.textContent = LANG_LABEL[other];
      btn.setAttribute("aria-label", SWITCH_ARIA[lang]);
    });

    try { localStorage.setItem(STORAGE_KEY, lang); } catch (e) {}
  }

  function init() {
    var current = detectLang();
    apply(current);
    document.querySelectorAll("[data-lang-toggle]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        current = current === "en" ? "zh" : "en";
        apply(current);
      });
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
