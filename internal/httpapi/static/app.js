const state = {
  token: sessionStorage.getItem("agentd_token") || "",
  apiReady: false,
  apiError: "",
  projects: [],
  projectsByID: new Map(),
  projectIDsSignature: "",
  sessions: [],
  sessionsByID: new Map(),
  sessionsByProjectID: new Map(),
  sessionsCursor: "",
  sessionsHasMore: false,
  sessionsLoading: false,
  sessionsRequestToken: 0,
  sessionsRenderSignature: "",
  historyPaging: {},
  selectedProject: "",
  sessionId: "",
  running: false,
  ws: null,
  autoScroll: true,
  messages: loadStoredMessages(),
  assistantTranscript: "",
  assistantLast: "",
  assistantTimer: null,
  assistantPending: "",
  terminalResizeTimer: null,
  messagesSaveTimer: null,
  messagesDirty: false,
  outputSeqBySession: {},
};

const SESSION_PAGE_LIMIT = 80;
const STORED_MESSAGES_SAVE_DELAY = 250;

const el = {
  endpoint: document.getElementById("endpoint"),
  apiStatus: document.getElementById("api-status"),
  sessionStatus: document.getElementById("session-status"),
  tokenInput: document.getElementById("token-input"),
  saveToken: document.getElementById("save-token"),
  refreshProjects: document.getElementById("refresh-projects"),
  projectSelect: document.getElementById("project-select"),
  projectPath: document.getElementById("project-path"),
  sessionsList: document.getElementById("sessions-list"),
  newSession: document.getElementById("new-session"),
  activeTitle: document.getElementById("active-title"),
  promptInput: document.getElementById("prompt-input"),
  startSession: document.getElementById("start-session"),
  stopSession: document.getElementById("stop-session"),
  sessionId: document.getElementById("session-id"),
  terminal: document.getElementById("terminal-output"),
  autoScroll: document.getElementById("auto-scroll"),
  clearOutput: document.getElementById("clear-output"),
  messages: document.getElementById("messages"),
  sendInput: document.getElementById("send-input"),
  sendEnter: document.getElementById("send-enter"),
  sendCtrlC: document.getElementById("send-ctrl-c"),
};

const terminalLog = window.createTerminalLog({
  element: el.terminal,
  onResize: sendResize,
  onData: (data) => {
    if (state.sessionId && currentSession()?.status === "running") {
      wsSend({ type: "input", data });
    }
  },
});

el.tokenInput.value = state.token;
el.endpoint.textContent = location.origin;

function authHeaders() {
  return { Authorization: `Bearer ${state.token}` };
}

async function api(path, options = {}) {
  const res = await fetch(path, {
    ...options,
    headers: {
      ...authHeaders(),
      ...(options.headers || {}),
    },
  });
  if (!res.ok) {
    let message = `${res.status} ${res.statusText}`;
    try {
      const body = await res.json();
      message = body.error || message;
    } catch (_) {}
    throw new Error(message);
  }
  return res.json();
}

function currentProject() {
  return state.projectsByID.get(state.selectedProject);
}

function currentSession() {
  return state.sessionsByID.get(state.sessionId);
}

function projectSessions() {
  return state.sessionsByProjectID.get(state.selectedProject) || [];
}

function sessionSortValue(session) {
  const parsed = Date.parse(session.updated_at || session.created_at || "");
  return Number.isNaN(parsed) ? 0 : parsed;
}

function sortSessions(sessions) {
  return sessions.slice().sort((a, b) => {
    const byTime = sessionSortValue(b) - sessionSortValue(a);
    if (byTime !== 0) return byTime;
    return String(b.id || "").localeCompare(String(a.id || ""));
  });
}

function setProjects(projects) {
  state.projects = projects || [];
  const byID = new Map();
  const ids = [];
  for (const project of state.projects) {
    if (!project?.id) continue;
    byID.set(project.id, project);
    ids.push(project.id);
  }
  state.projectsByID = byID;
  state.projectIDsSignature = ids.join("\u001f");
}

function setSessions(sessions) {
  state.sessions = sortSessions(sessions || []);
  rebuildSessionIndexes();
}

function rebuildSessionIndexes() {
  const byID = new Map();
  const byProjectID = new Map();

  // Web 端保持一个 sessions 源数组，同时维护按 id / project 的派生索引。
  // 渲染和 WebSocket 事件会高频读取当前会话，避免在这些路径里反复 find/filter。
  for (const session of state.sessions) {
    if (!session?.id) continue;
    byID.set(session.id, session);
    const projectID = session.project_id || "";
    let projectSessions = byProjectID.get(projectID);
    if (!projectSessions) {
      projectSessions = [];
      byProjectID.set(projectID, projectSessions);
    }
    projectSessions.push(session);
  }

  state.sessionsByID = byID;
  state.sessionsByProjectID = byProjectID;
}

function loadStoredMessages() {
  try {
    return JSON.parse(localStorage.getItem("agentd_messages_v1") || "{}");
  } catch (_) {
    return {};
  }
}

function saveStoredMessages() {
  state.messagesDirty = true;
  window.clearTimeout(state.messagesSaveTimer);
  // Litter 的本地状态写入会做短 debounce；这里同样把流式回复期间的多次
  // JSON 序列化和 localStorage 同步写合并成一批，降低主线程抖动。
  state.messagesSaveTimer = window.setTimeout(flushStoredMessages, STORED_MESSAGES_SAVE_DELAY);
}

function flushStoredMessages() {
  if (state.messagesSaveTimer) {
    window.clearTimeout(state.messagesSaveTimer);
    state.messagesSaveTimer = null;
  }
  if (!state.messagesDirty) return;
  state.messagesDirty = false;
  try {
    localStorage.setItem("agentd_messages_v1", JSON.stringify(state.messages));
  } catch (_) {}
}

function render() {
  const active = currentSession();
  state.running = active?.status === "running" || active?.status === "stopping";

  if (!state.token) {
    el.apiStatus.textContent = "未认证";
    el.apiStatus.className = "pill warn";
  } else if (state.apiReady) {
    el.apiStatus.textContent = "已连接";
    el.apiStatus.className = "pill ok";
  } else {
    el.apiStatus.textContent = state.apiError ? "连接失败" : "未验证";
    el.apiStatus.className = "pill warn";
  }
  el.sessionStatus.textContent = active ? displayStatus(active.status) : "无会话";
  el.sessionStatus.className = state.running ? "pill ok" : "pill";
  el.autoScroll.textContent = state.autoScroll ? "跟随开启" : "跟随关闭";
  el.autoScroll.className = state.autoScroll ? "log-toggle active" : "log-toggle";

  el.projectSelect.disabled = !state.token;
  el.refreshProjects.disabled = !state.token;
  el.newSession.disabled = !state.token || !state.selectedProject;
  el.startSession.disabled = !state.token || !state.selectedProject || state.running;
  el.stopSession.disabled = !state.running;
  el.sendInput.disabled = !state.token || !state.selectedProject;
  el.sendEnter.disabled = !state.running;
  el.sendCtrlC.disabled = !state.running;

  el.activeTitle.textContent = active ? active.title : state.projects.length ? "新任务" : "暂无项目";
  el.sessionId.textContent = `Session: ${state.sessionId || "-"}`;
  const project = currentProject();
  el.projectPath.textContent = project ? project.path : "暂无项目";
  renderSessions();
}

function renderSessions() {
  const sessions = projectSessions();
  const signature = sessionListSignature(sessions);
  if (state.sessionsRenderSignature === signature) return;
  state.sessionsRenderSignature = signature;

  el.sessionsList.innerHTML = "";
  if (state.projects.length === 0) {
    const empty = document.createElement("div");
    empty.className = "session-empty";
    empty.textContent = "没有项目，请检查 AGENTD_SCAN_ROOTS 或配置文件";
    el.sessionsList.appendChild(empty);
    return;
  }
  if (sessions.length === 0) {
    const empty = document.createElement("div");
    empty.className = "session-empty";
    empty.textContent = state.sessionsLoading ? "正在加载会话..." : "这个项目还没有会话";
    el.sessionsList.appendChild(empty);
    return;
  }
  for (const item of sessions) {
    const button = document.createElement("button");
    button.className = `session-item ${item.id === state.sessionId ? "active" : ""}`;
    button.onclick = () => attachSession(item.id);

    const title = document.createElement("div");
    title.className = "session-title";
    title.textContent = item.title || "Codex 会话";

    const meta = document.createElement("div");
    meta.className = "session-meta";
    const source = document.createElement("span");
    source.textContent = item.source === "codex" ? "Codex 历史" : displayStatus(item.status);
    const time = document.createElement("span");
    time.textContent = formatTime(item.updated_at || item.created_at);
    meta.appendChild(source);
    meta.appendChild(time);

    button.appendChild(title);
    button.appendChild(meta);
    el.sessionsList.appendChild(button);
  }
  if (state.sessionsHasMore || state.sessionsLoading) {
    const loadMore = document.createElement("button");
    loadMore.className = "session-load-more";
    loadMore.disabled = state.sessionsLoading;
    loadMore.textContent = state.sessionsLoading ? "正在加载..." : "加载更早会话";
    loadMore.onclick = loadMoreSessions;
    el.sessionsList.appendChild(loadMore);
  }
}

function sessionListSignature(sessions) {
  // 参考 Codex/Litter 的 projection no-op：先把会话列表投影成稳定签名。
  // 只要可见内容、选中态和加载态没变，就跳过整棵 DOM 重建。
  let signature = [
    state.selectedProject,
    state.sessionId,
    state.projectIDsSignature,
    state.sessionsLoading ? "1" : "0",
    state.sessionsHasMore ? "1" : "0",
  ].join("\u001e");
  for (const session of sessions) {
    signature += "\u001d";
    signature += [
      session.id,
      session.project_id,
      session.title,
      session.status,
      session.source,
      session.updated_at,
      session.created_at,
    ].join("\u001f");
  }
  return signature;
}

function displayStatus(status) {
  switch (status) {
    case "running":
      return "运行中";
    case "history":
      return "历史";
    case "waiting_for_input":
      return "待输入";
    case "waiting_for_approval":
      return "待审批";
    case "completed":
      return "完成";
    case "failed":
      return "失败";
    case "closed":
      return "已结束";
    case "idle":
      return "空闲";
    default:
      return String(status || "").replaceAll("_", " ");
  }
}

function formatTime(value) {
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" });
}

function resetMessages(title = "今天要让 Codex 做什么？", detail = "左侧选择项目和历史会话。中间是对话区，右侧是完整终端日志。") {
  el.messages.innerHTML = "";
  const empty = document.createElement("div");
  empty.className = "empty-state";
  empty.innerHTML = `<h2></h2><p></p>`;
  empty.querySelector("h2").textContent = title;
  empty.querySelector("p").textContent = detail;
  el.messages.appendChild(empty);
}

function clearWelcome() {
  const empty = el.messages.querySelector(".empty-state");
  if (empty) empty.remove();
}

function localMessageKey(kind, text) {
  return `${kind}:${text}`;
}

function historyItemKind(item) {
  return item.role === "assistant" ? "assistant" : "user";
}

function historyItemKey(item) {
  const kind = historyItemKind(item);
  return item.id ? `${kind}:id:${item.id}` : `${kind}:content:${item.content}`;
}

function historyPaging(sessionID) {
  state.historyPaging[sessionID] ||= {
    previousCursor: "",
    hasMoreBefore: false,
    loading: false,
    requestToken: 0,
    loadedKeys: new Set(),
  };
  return state.historyPaging[sessionID];
}

function renderHistoryLoadMoreButton(sessionID) {
  el.messages.querySelector(".history-load-more-row")?.remove();
  const paging = state.historyPaging[sessionID];
  if (!paging?.hasMoreBefore && !paging?.loading) return;

  const row = document.createElement("div");
  row.className = "history-load-more-row";
  const button = document.createElement("button");
  button.className = "history-load-more";
  button.disabled = paging.loading;
  button.textContent = paging.loading ? "正在加载..." : "加载更早消息";
  button.onclick = () => loadEarlierHistoryMessages(sessionID);
  row.appendChild(button);
  el.messages.prepend(row);
}

function addMessage(kind, text, persist = true, options = {}) {
  clearWelcome();
  const row = document.createElement("div");
  row.className = `message ${kind}`;
  const bubble = document.createElement("div");
  bubble.className = "bubble";
  bubble.textContent = text;
  row.appendChild(bubble);
  if (options.prepend) {
    const loadMoreRow = el.messages.querySelector(".history-load-more-row");
    el.messages.insertBefore(row, loadMoreRow?.nextSibling || el.messages.firstChild);
  } else {
    el.messages.appendChild(row);
  }
  if (options.scroll !== false) {
    el.messages.scrollTop = el.messages.scrollHeight;
  }
  if (persist && state.sessionId) {
    const list = state.messages[state.sessionId] || [];
    list.push({ kind, text, at: Date.now() });
    state.messages[state.sessionId] = list.slice(-80);
    saveStoredMessages();
  }
  return bubble;
}

function renderHistoryMessages(items, sessionID, options = {}) {
  const paging = historyPaging(sessionID);
  let rendered = 0;
  for (const item of items) {
    const text = item.content || "";
    if (!text) continue;
    const key = historyItemKey(item);
    if (paging.loadedKeys.has(key)) continue;
    paging.loadedKeys.add(key);
    addMessage(historyItemKind(item), text, false, options);
    rendered++;
  }
  return rendered;
}

async function loadSessionMessages(session) {
  const list = state.messages[session.id] || [];
  const seen = new Set();
  let rendered = false;
  el.messages.innerHTML = "";
  const requestToken = (state.historyPaging[session.id]?.requestToken || 0) + 1;
  state.historyPaging[session.id] = {
    previousCursor: "",
    hasMoreBefore: false,
    loading: false,
    requestToken,
    loadedKeys: new Set(),
  };

  if (session.source === "codex" || session.resume_id) {
    try {
      const data = await api(`/api/sessions/${session.id}/messages?limit=120`);
      const paging = historyPaging(session.id);
      if (state.sessionId !== session.id || paging.requestToken !== requestToken) return;
      paging.previousCursor = data.previous_cursor || "";
      paging.hasMoreBefore = Boolean(data.has_more_before && paging.previousCursor);
      renderHistoryLoadMoreButton(session.id);
      for (const item of data.messages || []) {
        seen.add(localMessageKey(historyItemKind(item), item.content));
      }
      rendered = renderHistoryMessages(data.messages || [], session.id, { scroll: false }) > 0;
      if (rendered) el.messages.scrollTop = el.messages.scrollHeight;
    } catch (err) {
      if (state.sessionId === session.id) {
        writeLog(`历史消息读取失败：${err.message}`);
      }
    }
  }

  if (state.sessionId !== session.id || historyPaging(session.id).requestToken !== requestToken) return;

  for (const item of list) {
    const key = localMessageKey(item.kind, item.text);
    if (seen.has(key)) continue;
    addMessage(item.kind, item.text, false);
    rendered = true;
  }

  if (!rendered) {
    if (session.source === "codex" || session.resume_id) {
      resetMessages(session.title || "Codex 历史会话", "这是 Codex 自带历史。点击“启动”或直接发送新指令，会通过 codex resume 继续这个会话。");
      return;
    }
    resetMessages(session.title || "已选择会话", "已重新接入该会话。右侧会回放最近终端输出。");
    return;
  }
}

async function loadEarlierHistoryMessages(sessionID) {
  const paging = historyPaging(sessionID);
  if (!paging.hasMoreBefore || paging.loading || !paging.previousCursor) return;

  const requestToken = paging.requestToken + 1;
  paging.requestToken = requestToken;
  paging.loading = true;
  renderHistoryLoadMoreButton(sessionID);

  const previousHeight = el.messages.scrollHeight;
  const previousTop = el.messages.scrollTop;
  try {
    const params = new URLSearchParams({
      limit: "120",
      before: paging.previousCursor,
    });
    const data = await api(`/api/sessions/${sessionID}/messages?${params.toString()}`);
    if (state.sessionId !== sessionID || paging.requestToken !== requestToken) return;

    paging.previousCursor = data.previous_cursor || "";
    paging.hasMoreBefore = Boolean(data.has_more_before && paging.previousCursor);
    paging.loading = false;
    renderHistoryLoadMoreButton(sessionID);
    renderHistoryMessages(data.messages || [], sessionID, { prepend: true, scroll: false });
    el.messages.scrollTop = previousTop + (el.messages.scrollHeight - previousHeight);
  } catch (err) {
    if (state.sessionId === sessionID) {
      writeLog(`更早历史消息读取失败：${err.message}`);
    }
  } finally {
    if (paging.requestToken === requestToken && paging.loading) {
      paging.loading = false;
      if (state.sessionId === sessionID) renderHistoryLoadMoreButton(sessionID);
    }
  }
}

function fitTerminal() {
  terminalLog.fit();
}

function terminalSize() {
  return terminalLog.size();
}

function writeLog(text) {
  terminalLog.writeAgent(text);
}

function textInputFocused() {
  return document.activeElement === el.promptInput || document.activeElement === el.tokenInput;
}

function scheduleTerminalFit() {
  window.clearTimeout(state.terminalResizeTimer);
  if (textInputFocused()) {
    ensureFocusedInputVisible();
    return;
  }
  state.terminalResizeTimer = window.setTimeout(fitTerminal, 120);
}

function updateViewportHeight() {
  const viewport = window.visualViewport;
  const height = viewport?.height || window.innerHeight;
  document.documentElement.style.setProperty("--app-height", `${Math.round(height)}px`);
  if (textInputFocused()) ensureFocusedInputVisible();
}

function ensureFocusedInputVisible() {
  window.setTimeout(() => {
    const active = document.activeElement;
    if (active === el.promptInput || active === el.tokenInput) {
      active.scrollIntoView({ block: "nearest", inline: "nearest" });
    }
  }, 80);
}

function resetTerminal(options = {}) {
  state.assistantTranscript = "";
  state.assistantPending = "";
  state.assistantLast = "";
  if (state.sessionId && !options.preserveSeq) delete state.outputSeqBySession[state.sessionId];
  terminalLog.reset();
}

function sessionAfterSeq(sessionID) {
  return state.outputSeqBySession[sessionID] || 0;
}

function queueTerminalOutput(text, seq, sessionID = state.sessionId) {
  if (sessionID && Number.isFinite(seq) && seq > 0) {
    const lastSeq = state.outputSeqBySession[sessionID] || 0;
    if (seq <= lastSeq) return;
    // 服务端的 recent_output 和实时块共享同一条单调水位；Web 端只在有 seq 时去重，
    // 保持旧 agentd/旧浏览器路径兼容。
    state.outputSeqBySession[sessionID] = seq;
  }
  observeAssistantText(text);
  terminalLog.append(text);
}

function stripAnsi(text) {
  return text
    .replace(/\x1b\][^\x07]*(\x07|\x1b\\)/g, "")
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, "");
}

function observeAssistantText(raw) {
  const clean = stripAnsi(raw).replace(/\r/g, "\n");
  if (!clean.trim()) return;
  state.assistantPending = (state.assistantPending + "\n" + clean).slice(-12000);
  window.clearTimeout(state.assistantTimer);
  state.assistantTimer = window.setTimeout(processAssistantPending, 800);
}

function processAssistantPending() {
  if (!state.assistantPending.trim()) return;
  state.assistantTranscript = (state.assistantTranscript + "\n" + state.assistantPending).slice(-24000);
  state.assistantPending = "";
  const candidate = latestAssistantBlock(state.assistantTranscript);
  if (candidate && candidate !== state.assistantLast) {
    state.assistantLast = candidate;
    addOrUpdateAssistant(candidate);
  }
}

function latestAssistantBlock(text) {
  const lines = text
    .split("\n")
    .map((line) => line.replace(/[╭╮╰╯│─┌┐└┘├┤┬┴┼]/g, " ").trim())
    .filter(Boolean);
  let start = -1;
  for (let i = lines.length - 1; i >= 0; i--) {
    if (isAssistantStartLine(lines[i])) {
      start = i;
      break;
    }
  }
  if (start < 0) return "";
  const parts = [];
  for (let i = start; i < Math.min(lines.length, start + 16); i++) {
    if (parts.length && shouldStopAfterAssistantStart(lines[i])) break;
    let line = lines[i].replace(/^.*?[•●]\s+/, "").trim();
    if (!line) continue;
    if (isTerminalChrome(line) || isStatusLine(line) || isStatusFragment(line)) break;
    parts.push(line);
  }
  const textOut = parts.join("\n").trim();
  if (textOut.length < 2) return "";
  return textOut.slice(0, 4000);
}

function isAssistantStartLine(line) {
  const trimmed = line.trim();
  if (!/^[•●]\s+/.test(trimmed)) return false;
  const content = trimmed.replace(/^[•●]\s+/, "").trim();
  return Boolean(content) && !isTerminalChrome(content) && !isStatusLine(trimmed) && !isStatusLine(content) && !isStatusFragment(content);
}

function shouldStopAfterAssistantStart(line) {
  const trimmed = line.trim();
  if (isTerminalChrome(trimmed) || isStatusLine(trimmed) || isStatusFragment(trimmed)) return true;
  return /^[•●]\s+/.test(trimmed);
}

function isTerminalChrome(line) {
  return /^(›|>|model:|directory:|permissions:|Run |Starting MCP|Tip:|\[agentd\])/.test(line) ||
    /^(OpenAI Codex|Under-development features enabled)/.test(line);
}

function isStatusLine(line) {
  return line.includes("esc to interrupt") ||
    /^Working/.test(line) ||
    /^[◦⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/.test(line);
}

function isStatusFragment(line) {
  const trimmed = line.trim();
  if (!trimmed) return true;
  if ("Working".startsWith(trimmed)) return true;
  return trimmed.length <= 3 && /^\d+$/.test(trimmed);
}

function addOrUpdateAssistant(text) {
  const last = el.messages.querySelector(".message.assistant:last-child .bubble");
  if (last) {
    last.textContent = text;
    const list = state.messages[state.sessionId] || [];
    if (list.length && list[list.length - 1].kind === "assistant") {
      list[list.length - 1].text = text;
      list[list.length - 1].at = Date.now();
      state.messages[state.sessionId] = list;
      saveStoredMessages();
      return;
    }
  }
  addMessage("assistant", text);
}

async function loadProjects(keepSelection = false, autoAttachLatest = false) {
  const previous = state.selectedProject;
  const data = await api("/api/projects");
  state.apiReady = true;
  state.apiError = "";
  setProjects(data.projects || []);
  el.projectSelect.innerHTML = "";
  for (const project of state.projects) {
    const option = document.createElement("option");
    option.value = project.id;
    option.textContent = project.name;
    el.projectSelect.appendChild(option);
  }
  if (keepSelection && state.projectsByID.has(previous)) {
    state.selectedProject = previous;
  } else {
    state.selectedProject = state.projects[0]?.id || "";
  }
  el.projectSelect.value = state.selectedProject;
  await loadSessions(autoAttachLatest);
  render();
}

function mergeSessionPage(page, projectID, append) {
  const selected = currentSession();
  if (append) {
    const byID = new Map(state.sessionsByID);
    for (const item of page) {
      if (item?.id) byID.set(item.id, item);
    }
    setSessions(Array.from(byID.values()));
    return;
  }

  const pageIDs = new Set(page.map((item) => item.id));
  const scopedPage = page.slice();
  if (selected && selected.project_id === projectID && !pageIDs.has(selected.id)) {
    scopedPage.push(selected);
  }
  if (!projectID) {
    setSessions(scopedPage);
    return;
  }
  const merged = [];
  for (const item of state.sessions) {
    if (item.project_id !== projectID) merged.push(item);
  }
  merged.push(...scopedPage);
  setSessions(merged);
}

async function loadSessions(autoAttachLatest = false, options = {}) {
  const append = Boolean(options.append);
  if (append && (!state.sessionsHasMore || state.sessionsLoading)) return;

  const projectID = state.selectedProject;
  const cursor = append ? state.sessionsCursor : "";
  const requestToken = state.sessionsRequestToken + 1;
  state.sessionsRequestToken = requestToken;
  state.sessionsLoading = true;
  renderSessions();

  if (!append) {
    state.sessionsCursor = "";
    state.sessionsHasMore = false;
  }

  try {
    const params = new URLSearchParams({ limit: String(SESSION_PAGE_LIMIT) });
    if (projectID) params.set("project_id", projectID);
    if (cursor) params.set("cursor", cursor);
    const data = await api(`/api/sessions?${params.toString()}`);
    if (requestToken !== state.sessionsRequestToken) return;

    mergeSessionPage(data.sessions || [], projectID, append);
    state.sessionsCursor = data.next_cursor || "";
    state.sessionsHasMore = Boolean(data.has_more && state.sessionsCursor);
  } finally {
    if (requestToken === state.sessionsRequestToken) {
      state.sessionsLoading = false;
    }
  }

  if (state.sessionId && !state.sessionsByID.has(state.sessionId)) {
    state.sessionId = "";
  }
  if (autoAttachLatest) {
    const latest = projectSessions().find((s) => s.status === "running");
    if (latest) await attachSession(latest.id);
  }
}

function loadMoreSessions() {
  loadSessions(false, { append: true })
    .then(render)
    .catch((err) => writeLog(`加载更多会话失败：${err.message}`));
}

async function startSession(options = {}) {
  const selected = currentSession();
  const resume = options.resume || (selected?.source === "codex" ? selected : null);
  const prompt = options.prompt ?? el.promptInput.value.trim();
  const size = terminalSize();
  const data = await api("/api/sessions", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      project_id: resume?.project_id || state.selectedProject,
      prompt,
      resume_id: resume?.resume_id || "",
      title: resume?.title || "",
      cols: size.cols,
      rows: size.rows,
    }),
  });
  upsertSession(data.session);
  state.sessionId = data.session.id;
  resetTerminal();
  if (resume) {
    await loadSessionMessages(data.session);
    if (prompt) addMessage("user", prompt);
    addMessage("system", "已继续这个 Codex 历史会话。");
  } else {
    resetMessages();
    addMessage("user", prompt || "启动交互式 Codex 会话");
    addMessage("system", "Codex 已启动。可以继续在下方输入，右侧日志会显示完整终端输出。");
  }
  el.promptInput.value = "";
  render();
  connectWS(data.session.id);
}

async function attachSession(id) {
  if (state.ws) {
    state.ws.close();
    state.ws = null;
  }
  state.sessionId = id;
  resetTerminal({ preserveSeq: true });
  const session = currentSession();
  if (!session) return;
  await loadSessionMessages(session);
  render();
  if (session.source === "codex" && session.status === "history") {
    return;
  }
  connectWS(id);
}

function connectWS(id) {
  const protocol = location.protocol === "https:" ? "wss" : "ws";
  const params = new URLSearchParams({ token: state.token });
  const afterSeq = sessionAfterSeq(id);
  if (afterSeq > 0) params.set("after_seq", String(afterSeq));
  const url = `${protocol}://${location.host}/api/sessions/${id}/ws?${params.toString()}`;
  const ws = new WebSocket(url);
  state.ws = ws;

  ws.onopen = () => {
    writeLog("WebSocket 已连接");
    fitTerminal();
    sendResize();
  };
  ws.onmessage = (event) => {
    const msg = JSON.parse(event.data);
    if (msg.type === "session" && msg.session) {
      upsertSession(msg.session);
      render();
    } else if (msg.type === "output") {
      queueTerminalOutput(msg.data || "", Number(msg.seq), msg.session_id || id);
    } else if (msg.type === "exit") {
      const active = currentSession();
      if (active) active.status = "closed";
      writeLog(`Session 已退出：${JSON.stringify(msg.exit)}`);
      addMessage("system", "Codex 会话已结束。");
      render();
      loadSessions(false).then(render).catch(() => {});
    } else if (msg.type === "error") {
      writeLog(`错误：${msg.error}`);
    }
  };
  ws.onclose = () => {
    if (state.sessionId === id && currentSession()?.status === "running") {
      writeLog("WebSocket 已断开，可点击左侧会话重新接入");
    }
  };
}

function upsertSession(session) {
  if (!session?.id) return;
  const byID = new Map(state.sessionsByID);
  byID.set(session.id, session);
  setSessions(Array.from(byID.values()));
}

function wsSend(payload) {
  if (!state.ws || state.ws.readyState !== WebSocket.OPEN) {
    writeLog("WebSocket 未连接");
    return false;
  }
  state.ws.send(JSON.stringify(payload));
  return true;
}

function sendResize(size = terminalSize()) {
  if (!state.sessionId || !state.ws || state.ws.readyState !== WebSocket.OPEN) return;
  wsSend({ type: "resize", cols: size.cols, rows: size.rows });
}

function sendComposer() {
  const text = el.promptInput.value;
  if (!text.trim()) return;
  const active = currentSession();
  if (!state.sessionId || !active || active.status !== "running") {
    startSession({ resume: active?.source === "codex" ? active : null, prompt: text.trim() }).catch((err) => writeLog(err.message));
    return;
  }
  // 交互式终端里的 Enter 是 CR，不是普通 LF；这里模拟真实键盘输入。
  if (wsSend({ type: "input", data: `${text}\r` })) {
    state.assistantLast = "";
    addMessage("user", text);
    el.promptInput.value = "";
  }
}

el.saveToken.onclick = async () => {
  state.token = el.tokenInput.value.trim();
  state.apiReady = false;
  state.apiError = "";
  sessionStorage.setItem("agentd_token", state.token);
  render();
  try {
    await loadProjects(false, true);
    writeLog("项目和会话已加载");
  } catch (err) {
    state.apiReady = false;
    state.apiError = err.message;
    render();
    writeLog(`认证或加载失败：${err.message}`);
  }
};

el.refreshProjects.onclick = () =>
  loadProjects(true).catch((err) => {
    state.apiReady = false;
    state.apiError = err.message;
    render();
    writeLog(err.message);
  });
el.projectSelect.onchange = async () => {
  state.selectedProject = el.projectSelect.value;
  state.sessionId = "";
  if (state.ws) state.ws.close();
  resetTerminal();
  resetMessages();
  await loadSessions(false).catch((err) => writeLog(err.message));
  render();
};
el.newSession.onclick = () => {
  if (state.ws) state.ws.close();
  state.sessionId = "";
  resetTerminal();
  resetMessages("新任务", "输入任务后点击发送或启动，会在当前项目下创建一个新的 Codex 会话。");
  render();
  el.promptInput.focus();
};
el.startSession.onclick = () => startSession().catch((err) => writeLog(err.message));
el.stopSession.onclick = async () => {
  if (!state.sessionId) return;
  await api(`/api/sessions/${state.sessionId}`, { method: "DELETE" });
  await loadSessions(false);
  render();
};
el.clearOutput.onclick = resetTerminal;
el.autoScroll.onclick = () => {
  state.autoScroll = !state.autoScroll;
  terminalLog.setAutoScroll(state.autoScroll);
  render();
  if (state.autoScroll) terminalLog.scrollToBottom();
};
el.sendInput.onclick = sendComposer;
el.sendEnter.onclick = () => wsSend({ type: "input", data: "\r" });
el.sendCtrlC.onclick = () => wsSend({ type: "signal", data: "ctrl_c" });
el.promptInput.addEventListener("keydown", (event) => {
  if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
    event.preventDefault();
    sendComposer();
  }
});
el.promptInput.addEventListener("blur", scheduleTerminalFit);
el.tokenInput.addEventListener("blur", scheduleTerminalFit);
el.promptInput.addEventListener("focus", ensureFocusedInputVisible);
el.tokenInput.addEventListener("focus", ensureFocusedInputVisible);
el.sessionsList.addEventListener("scroll", () => {
  const remaining = el.sessionsList.scrollHeight - el.sessionsList.scrollTop - el.sessionsList.clientHeight;
  if (remaining < 140) loadMoreSessions();
});
window.addEventListener("resize", scheduleTerminalFit);
window.addEventListener("resize", updateViewportHeight);
window.addEventListener("pagehide", flushStoredMessages);
window.addEventListener("beforeunload", flushStoredMessages);
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "hidden") flushStoredMessages();
});
window.visualViewport?.addEventListener("resize", () => {
  updateViewportHeight();
  scheduleTerminalFit();
});
window.visualViewport?.addEventListener("scroll", updateViewportHeight);

if ("ResizeObserver" in window) {
  new ResizeObserver(scheduleTerminalFit).observe(el.terminal);
}

if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker
      .register("/sw.js")
      .then(() => writeLog("PWA 缓存已启用"))
      .catch(() => writeLog("PWA 缓存需要 HTTPS 或 localhost"));
  });
}

render();
updateViewportHeight();
writeLog("等待连接");
if (state.token) {
  loadProjects(false, true)
    .catch((err) => {
      state.apiReady = false;
      state.apiError = err.message;
      render();
      writeLog(`自动连接失败：${err.message}`);
    });
}
