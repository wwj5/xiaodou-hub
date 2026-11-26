/* 小豆邀请码互助站 · 前端逻辑（揭晓制）
 * remote —— 配置了 Supabase，数据全站共享；列表永不含明文，只有 reveal 才出码
 * demo   —— 未配置时降级为浏览器 localStorage，语义与远端一致，方便先看效果
 */

(function () {
  "use strict";

  const CFG = Object.assign(
    {
      supabaseUrl: "",
      supabaseKey: "",
      codeMinLen: 4,
      codeMaxLen: 32,
      maxSpots: 30,
      dailyReveals: 2,
      maxPublish: 1,
    },
    window.HUB_CONFIG || {}
  );

  const MODE = CFG.supabaseUrl && CFG.supabaseKey ? "remote" : "demo";

  const $ = (sel) => document.querySelector(sel);
  const TOKEN_KEY = "xd:visitor";
  const ADMIN_KEY = "xd:admin";
  const MINE_KEY = "xd:mymask";     // 只本地保存"我揭晓到的码"
  const DEMO_KEY = "xd:demo:v2";

  /* ------------------------------------------------------------ 工具 */

  function esc(str) {
    return String(str == null ? "" : str).replace(/[&<>"']/g, (c) => (
      { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
    ));
  }

  function visitorToken() {
    let t = localStorage.getItem(TOKEN_KEY);
    if (!t) {
      t = (crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(36).slice(2) + Date.now()) +
          Date.now().toString(36);
      localStorage.setItem(TOKEN_KEY, t);
    }
    return t;
  }

  function normalizeCode(raw) {
    return String(raw || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
  }

  function beijingDate() {
    return new Date(Date.now() + 8 * 3600 * 1000).toISOString().slice(0, 10);
  }

  function timeAgo(iso) {
    const t = new Date(iso).getTime();
    if (!t) return "—";
    const diff = (Date.now() - t) / 1000;
    if (diff < 60) return "刚刚";
    if (diff < 3600) return Math.floor(diff / 60) + " 分钟前";
    if (diff < 86400) return Math.floor(diff / 3600) + " 小时前";
    return Math.floor(diff / 86400) + " 天前";
  }

  let toastTimer = null;
  function toast(msg, bad) {
    const el = $("#toast");
    el.textContent = msg;
    el.hidden = false;
    el.classList.toggle("bad", !!bad);
    requestAnimationFrame(() => el.classList.add("show"));
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => {
      el.classList.remove("show");
      setTimeout(() => { el.hidden = true; }, 260);
    }, 2400);
  }

  async function copyText(text) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch (e) {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      let ok = false;
      try { ok = document.execCommand("copy"); } catch (err) { ok = false; }
      document.body.removeChild(ta);
      return ok;
    }
  }

  function fail(msg) {
    const e = new Error(msg);
    e.isApi = true;
    return e;
  }

  /* 我揭晓到的码：本地缓存 */
  const mine = {
    all() {
      try { return JSON.parse(localStorage.getItem(MINE_KEY) || "{}"); } catch (e) { return {}; }
    },
    has(id) { return !!this.all()[id]; },
    get(id) { return this.all()[id] || null; },
    add(id, code) {
      const m = this.all();
      m[id] = { code, at: new Date().toISOString() };
      // 只留最近 50 条
      const keys = Object.keys(m).sort((a, b) => (m[a].at < m[b].at ? 1 : -1));
      const trimmed = {};
      keys.slice(0, 50).forEach((k) => { trimmed[k] = m[k]; });
      localStorage.setItem(MINE_KEY, JSON.stringify(trimmed));
    },
  };

  /* ------------------------------------------------------------ 远端（Supabase） */

  function sbBase() {
    return String(CFG.supabaseUrl).trim().replace(/\/+$/, "").replace(/\/rest\/v1$/, "");
  }

  async function rpc(fn, params) {
    const res = await fetch(sbBase() + "/rest/v1/rpc/" + fn, {
      method: "POST",
      headers: {
        apikey: CFG.supabaseKey,
        Authorization: "Bearer " + CFG.supabaseKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(params || {}),
    });
    const text = await res.text();
    let data = null;
    try { data = text ? JSON.parse(text) : null; } catch (e) { data = null; }
    if (!res.ok) {
      throw fail((data && (data.message || data.hint)) || "请求失败（HTTP " + res.status + "）");
    }
    return data;
  }

  /* ------------------------------------------------------------ 演示后端 */

  const demo = {
    read() {
      let raw = localStorage.getItem(DEMO_KEY);
      if (!raw) {
        const now = new Date().toISOString();
        raw = JSON.stringify({
          codes: [
            { id: "seed-1", code: "XD2026AB", status: "available", totalSpots: 5, remainingSpots: 3,
              claimedCount: 2, queueRank: 1, createdAt: now, creator: "seed" },
            { id: "seed-2", code: "XIAODOU7", status: "used", totalSpots: 2, remainingSpots: 0,
              claimedCount: 2, queueRank: 2, createdAt: now, creator: "seed" },
          ],
          reveals: {},   // token -> {date, n}
          reports: {},   // token|id -> true
          seq: 2,
        });
        localStorage.setItem(DEMO_KEY, raw);
      }
      return JSON.parse(raw);
    },
    write(s) { localStorage.setItem(DEMO_KEY, JSON.stringify(s)); },
    stats(s) {
      const avail = s.codes.filter((c) => c.status === "available");
      return {
        issued: s.codes.length,
        available: avail.length,
        revealed: s.codes.length - avail.length,
        revealedCount: s.codes.reduce((n, c) => n + (c.claimedCount || 0), 0),
        availableSpots: avail.reduce((n, c) => n + c.remainingSpots, 0),
      };
    },
    publicCard(c) {
      return {
        id: c.id,
        mask: "•".repeat(Math.max(4, c.code.length)),
        status: c.status,
        totalSpots: c.totalSpots,
        remainingSpots: c.remainingSpots,
        claimedCount: c.claimedCount,
        queueRank: c.queueRank,
        createdAt: c.createdAt,
      };
    },
    quota(token, s) {
      const rec = s.reveals[token];
      const today = beijingDate();
      const used = rec && rec.date === today ? rec.n : 0;
      return { remaining: Math.max(0, CFG.dailyReveals - used), limit: CFG.dailyReveals, resetAt: "北京时间 00:00" };
    },
    async list(status, q, token) {
      const s = this.read();
      const norm = normalizeCode(q);
      let rows = s.codes.slice();
      if (status === "available") rows = rows.filter((c) => c.status === "available");
      else if (status === "used") rows = rows.filter((c) => c.status !== "available");
      if (norm) rows = rows.filter((c) => c.code.includes(norm));
      rows.sort((a, b) => a.queueRank - b.queueRank);
      return {
        ok: true,
        cards: rows.map((c) => this.publicCard(c)),
        stats: this.stats(s),
        quota: this.quota(token, s),
      };
    },
    async publish(code, spots, token) {
      const s = this.read();
      const norm = normalizeCode(code);
      if (norm.length < CFG.codeMinLen || norm.length > CFG.codeMaxLen) {
        throw fail("邀请码长度需为 " + CFG.codeMinLen + "–" + CFG.codeMaxLen + " 位字母或数字");
      }
      if (spots < 1 || spots > CFG.maxSpots) throw fail("剩余次数必须是 1–30 的整数");
      if (s.codes.some((c) => c.code === norm)) throw fail("该邀请码已经在池里了");
      if (s.codes.some((c) => c.creator === token && c.status === "available")) {
        throw fail("同一个人最多保留 1 个可用邀请码");
      }
      const rank = s.codes.reduce((m, c) => Math.max(m, c.queueRank), 0) + 1;
      const row = {
        id: "demo-" + (s.seq + 1), code: norm, status: "available", totalSpots: spots,
        remainingSpots: spots, claimedCount: 0, queueRank: rank, createdAt: new Date().toISOString(),
        creator: token,
      };
      s.seq += 1;
      s.codes.push(row);
      this.write(s);
      return { ok: true, card: this.publicCard(row), stats: this.stats(s) };
    },
    async reveal(id, token) {
      const s = this.read();
      const today = beijingDate();
      const rec = s.reveals[token];
      const used = rec && rec.date === today ? rec.n : 0;
      if (used >= CFG.dailyReveals) {
        throw fail("今天的揭晓次数用完了（每人每天 " + CFG.dailyReveals + " 次，北京时间 00:00 重置）");
      }
      const row = s.codes.find((c) => c.id === id);
      if (!row) throw fail("这个邀请码不存在了");
      if (row.status !== "available" || row.remainingSpots <= 0) throw fail("这个邀请码已经被别人揭晓了");
      if (s.reports[token + "|" + id]) throw fail("你已经揭晓过这个码了");

      row.remainingSpots -= 1;
      row.claimedCount += 1;
      if (row.remainingSpots <= 0) row.status = "used";
      s.reports[token + "|" + id] = true;
      s.reveals[token] = { date: today, n: used + 1 };
      this.write(s);
      return {
        ok: true,
        code: row.code,
        card: { ...this.publicCard(row), code: row.code },
        stats: this.stats(s),
        quotaRemaining: Math.max(0, CFG.dailyReveals - used - 1),
      };
    },
    async feedback(id, reason, note, token) {
      const s = this.read();
      if (!s.codes.some((c) => c.id === id)) throw fail("邀请码不存在");
      const key = token + "|" + id + "|" + reason;
      s.feedbacks = s.feedbacks || {};
      if (s.feedbacks[key]) throw fail("你已经反馈过同样的原因了");
      s.feedbacks[key] = { reason, note: String(note || "").slice(0, 300), at: new Date().toISOString() };
      this.write(s);
      return { ok: true };
    },
    async admin() { throw fail("演示模式没有管理后台：配上 Supabase 才能管理全站"); },
  };

  /* ------------------------------------------------------------ 统一 API */

  const api = {
    list(status, q) {
      return MODE === "remote"
        ? rpc("list_codes", { p_status: status, p_query: q, p_limit: 500, p_offset: 0, p_token: visitorToken() })
        : demo.list(status, q, visitorToken());
    },
    publish(code, spots) {
      return MODE === "remote"
        ? rpc("publish_code", { p_code: code, p_spots: spots, p_token: visitorToken() })
        : demo.publish(code, spots, visitorToken());
    },
    reveal(id) {
      return MODE === "remote"
        ? rpc("reveal_code", { p_id: id, p_token: visitorToken() })
        : demo.reveal(id, visitorToken());
    },
    feedback(id, reason, note) {
      return MODE === "remote"
        ? rpc("submit_feedback", { p_id: id, p_reason: reason, p_note: note, p_token: visitorToken() })
        : demo.feedback(id, reason, note, visitorToken());
    },
    adminVerify(key) {
      return MODE === "remote" ? rpc("admin_verify", { p_key: key }) : demo.admin();
    },
    adminFind(code, key) {
      return MODE === "remote" ? rpc("admin_find", { p_code: code, p_key: key }) : demo.admin();
    },
    adminUpdate(id, key, payload) {
      return MODE === "remote"
        ? rpc("admin_update", { p_id: id, p_key: key, p_remaining: payload.remaining, p_position: payload.position, p_status: payload.status })
        : demo.admin();
    },
    adminReseed(key) {
      return MODE === "remote" ? rpc("admin_reseed", { p_key: key }) : demo.admin();
    },
  };

  /* ------------------------------------------------------------ 状态 */

  const state = {
    filter: "available",
    query: "",
    cards: [],
    stats: { issued: 0, available: 0, revealed: 0, availableSpots: 0 },
    head: null,
    quota: null,
    busy: false,
    feedbackTarget: null,
  };

  /* ------------------------------------------------------------ 渲染 */

  function renderStats() {
    $("#statIssued").textContent = state.stats.issued ?? "—";
    $("#statAvailable").textContent = state.stats.available ?? "—";
    $("#statSpots").textContent = state.stats.revealedCount ?? state.stats.revealed ?? "—";
  }

  function renderHero() {
    const dot = $("#heroDot");
    const text = $("#heroStatus");
    if (MODE === "demo") {
      dot.className = "dot warn";
      text.textContent = "演示模式：数据只在这台浏览器里，配上 Supabase 才全站共享";
      return;
    }
    if (state.stats.available > 0) {
      dot.className = "dot";
      text.textContent = "已连接 · 现在有 " + state.stats.available + " 个码可以揭晓";
    } else {
      dot.className = "dot warn";
      text.textContent = "已连接 · 暂时没有可揭晓的码，等别人放";
    }
  }

  function renderPassport() {
    const box = $("#passport");
    const head = state.head;
    if (!head) { box.hidden = true; return; }
    box.hidden = false;

    const got = mine.get(head.id);
    const codeEl = $("#passportCode");
    codeEl.textContent = got ? got.code : head.mask;
    codeEl.classList.toggle("revealed", !!got);

    $("#passportRank").textContent = "顺位 #" + head.queueRank;
    $("#passportSpots").textContent = head.remainingSpots + " / " + head.totalSpots;
    $("#passportState").textContent = got
      ? "已领取（你）"
      : head.status === "available" ? "可揭晓" : "已被揭";
    $("#passportTime").textContent = timeAgo(head.createdAt);

    const q = state.quota;
    $("#quotaHint").textContent = q
      ? "今日揭晓名额：" + q.remaining + " / " + q.limit + "（" + (q.resetAt || "北京时间 00:00") + " 重置）"
      : "今日揭晓名额：—";

    $("#passportCopy").disabled = !got;
    const btn = $("#passportReveal");
    if (got) {
      btn.hidden = true;
    } else {
      btn.hidden = false;
      btn.disabled = head.status !== "available" || (q && q.remaining <= 0);
      btn.textContent = head.status === "available"
        ? (q && q.remaining <= 0 ? "今日名额已用完" : "点击揭晓")
        : "已被别人揭晓";
    }
  }

  function renderMine() {
    const m = mine.all();
    const entries = Object.values(m).sort((a, b) => (a.at < b.at ? 1 : -1));
    const card = $("#myCodesCard");
    if (!entries.length) { card.hidden = true; return; }
    card.hidden = false;
    $("#myCodes").innerHTML = entries.map((e) => (
      '<div class="mine-row">' +
        "<code>" + esc(e.code) + "</code>" +
        "<span>" + timeAgo(e.at) + "</span>" +
        '<button class="mini-btn" data-copy="' + esc(e.code) + '">复制</button>' +
      "</div>"
    )).join("");
  }

  function renderList() {
    const list = $("#list");
    if (!state.cards.length) {
      list.innerHTML = state.query
        ? '<div class="empty">没有码能用「' + esc(state.query) + '」搜到</div>'
        : '<div class="empty">' + (state.filter === "available"
            ? "暂时没有可揭晓的码，等你放第一个进来"
            : "这个分类下还没有记录") + "</div>";
      return;
    }
    list.innerHTML = state.cards.map((c) => {
      const got = mine.get(c.id);
      const dim = c.status === "available" ? "" : " dim";
      const pct = c.totalSpots ? Math.round((c.remainingSpots / c.totalSpots) * 100) : 0;
      const stateText = got ? "已领取（你）" : c.status === "available" ? "可揭晓" : "已被揭";
      const shown = got ? '<div class="row-code revealed">' + esc(got.code) + "</div>"
                        : '<div class="row-code masked">' + esc(c.mask) + "</div>";
      const actions = [
        got ? '<button class="mini-btn" data-act="copy" data-id="' + esc(c.id) + '">复制</button>' : "",
        (c.status === "available" && !got)
          ? '<button class="mini-btn solid" data-act="reveal" data-id="' + esc(c.id) + '">揭晓</button>'
          : "",
      ].join("");
      return (
        '<div class="row' + dim + '">' +
          '<div class="row-rank">#' + c.queueRank + "</div>" +
          '<div class="row-main">' + shown +
            '<div class="row-sub">' + stateText + " · " + timeAgo(c.createdAt) +
              " · 已揭 " + c.claimedCount + " 次</div>" +
          "</div>" +
          '<div class="row-spots"><span class="bar"><i style="width:' + pct + '%"></i></span>' +
            c.remainingSpots + " / " + c.totalSpots + "</div>" +
          '<div class="row-actions">' + actions + "</div>" +
        "</div>"
      );
    }).join("");
  }

  function renderAll() {
    renderStats();
    renderHero();
    renderPassport();
    renderMine();
    renderList();
  }

  /* ------------------------------------------------------------ 加载 */

  let loading = false;
  async function load() {
    if (loading) return;
    loading = true;
    try {
      const data = await api.list(state.filter, state.query);
      state.cards = data.cards || [];
      state.stats = data.stats || state.stats;
      if (data.quota) state.quota = data.quota;

      // 队首：优先取"还没被我揭晓过"的第一个可揭晓卡，避免队首一直是自己领过的那个
      const pickHead = (list) => {
        const avail = list.filter((c) => c.status === "available");
        return avail.find((c) => !mine.has(c.id)) || avail[0] || null;
      };
      if (state.filter === "available") {
        state.head = pickHead(state.cards);
      } else {
        const avail = (await api.list("available", "")).cards || [];
        state.head = pickHead(avail);
      }
      renderAll();
    } catch (e) {
      $("#list").innerHTML = '<div class="error-state">加载失败：' + esc(e.message) + "</div>";
      $("#heroDot").className = "dot bad";
      $("#heroStatus").textContent = "连接失败：" + e.message;
    } finally {
      loading = false;
    }
  }

  /* ------------------------------------------------------------ 交互 */

  function fillSpots() {
    const opts = [1, 2, 3, 5, 10, 20, 30].filter((n) => n <= CFG.maxSpots);
    $("#spotsInput").innerHTML = opts
      .map((n) => '<option value="' + n + '"' + (n === 3 ? " selected" : "") + ">" + n + " 次</option>")
      .join("");
  }

  async function doReveal(card) {
    if (state.busy) return;
    state.busy = true;
    try {
      const res = await api.reveal(card.id);
      mine.add(card.id, res.code);
      if (res.quotaRemaining != null && state.quota) state.quota = { ...state.quota, remaining: res.quotaRemaining };
      const ok = await copyText(res.code);
      toast("揭晓成功：" + res.code + (ok ? "，已复制到剪贴板" : "，请手动复制"), false);
      await load();
    } catch (e) {
      toast(e.message, true);
    } finally {
      state.busy = false;
    }
  }

  function wire() {
    $("#filter").addEventListener("click", (e) => {
      const btn = e.target.closest("button[data-status]");
      if (!btn) return;
      state.filter = btn.dataset.status;
      Array.from($("#filter").children).forEach((b) => b.classList.toggle("active", b === btn));
      $("#list").innerHTML = '<div class="loading">正在加载队列…</div>';
      load();
    });

    let searchTimer = null;
    $("#searchInput").addEventListener("input", (e) => {
      state.query = e.target.value;
      clearTimeout(searchTimer);
      searchTimer = setTimeout(load, 240);
    });

    $("#refreshBtn").addEventListener("click", () => { toast("已刷新"); load(); });

    $("#shareForm").addEventListener("submit", async (e) => {
      e.preventDefault();
      const errBox = $("#shareError");
      errBox.hidden = true;
      const code = normalizeCode($("#codeInput").value);
      const spots = parseInt($("#spotsInput").value, 10);
      if (code.length < CFG.codeMinLen || code.length > CFG.codeMaxLen) {
        errBox.textContent = "邀请码长度需为 " + CFG.codeMinLen + "–" + CFG.codeMaxLen + " 位字母或数字";
        errBox.hidden = false;
        return;
      }
      const btn = $("#shareSubmit");
      btn.disabled = true;
      btn.textContent = "提交中…";
      try {
        await api.publish(code, spots);
        $("#codeInput").value = "";
        toast("已放进队列：" + code);
        state.filter = "available";
        Array.from($("#filter").children).forEach((b) => b.classList.toggle("active", b.dataset.status === "available"));
        await load();
      } catch (err) {
        errBox.textContent = err.message;
        errBox.hidden = false;
      } finally {
        btn.disabled = false;
        btn.textContent = "立即分享";
      }
    });

    $("#passportReveal").addEventListener("click", async () => {
      if (state.head) await doReveal(state.head);
    });
    $("#passportCopy").addEventListener("click", async () => {
      if (!state.head) return;
      const got = mine.get(state.head.id);
      if (!got) return;
      const ok = await copyText(got.code);
      toast(ok ? "已复制：" + got.code : "复制失败，请手动选中", !ok);
    });
    $("#passportFeedback").addEventListener("click", () => {
      if (state.head) openFeedback(state.head);
    });

    $("#list").addEventListener("click", async (e) => {
      const btn = e.target.closest("button[data-act]");
      if (!btn) return;
      const id = btn.dataset.id;
      const card = state.cards.find((c) => String(c.id) === id) ||
                   (state.head && String(state.head.id) === id ? state.head : null);
      if (!card) return;
      if (btn.dataset.act === "reveal") {
        await doReveal(card);
      } else if (btn.dataset.act === "copy") {
        const got = mine.get(card.id);
        if (!got) return;
        const ok = await copyText(got.code);
        toast(ok ? "已复制：" + got.code : "复制失败，请手动选中", !ok);
      }
    });

    $("#myCodes").addEventListener("click", async (e) => {
      const btn = e.target.closest("button[data-copy]");
      if (!btn) return;
      const ok = await copyText(btn.dataset.copy);
      toast(ok ? "已复制：" + btn.dataset.copy : "复制失败", !ok);
    });

    // 管理
    $("#adminBtn").addEventListener("click", openAdmin);
    $("#adminClose").addEventListener("click", () => ($("#adminModal").hidden = true));
    $("#adminModal").addEventListener("click", (e) => {
      if (e.target.id === "adminModal") $("#adminModal").hidden = true;
    });
    $("#adminSave").addEventListener("click", async () => {
      const key = $("#adminKeyInput").value.trim();
      const err = $("#adminError");
      err.hidden = true;
      if (!key) { err.textContent = "先填密钥"; err.hidden = false; return; }
      try {
        await api.adminVerify(key);
        localStorage.setItem(ADMIN_KEY, key);
        $("#adminPanel").hidden = false;
        toast("管理密钥已导入");
      } catch (e) { err.textContent = e.message; err.hidden = false; }
    });
    $("#adminClear").addEventListener("click", () => {
      localStorage.removeItem(ADMIN_KEY);
      $("#adminKeyInput").value = "";
      $("#adminPanel").hidden = true;
      toast("已清除本地密钥");
    });
    $("#adminApply").addEventListener("click", async () => {
      const key = localStorage.getItem(ADMIN_KEY) || $("#adminKeyInput").value.trim();
      const code = normalizeCode($("#adminCodeInput").value);
      if (!code) { toast("先填邀请码", true); return; }
      try {
        const found = await api.adminFind(code, key);
        const remaining = $("#adminRemaining").value === "" ? null : parseInt($("#adminRemaining").value, 10);
        const position = $("#adminPosition").value === "" ? null : parseInt($("#adminPosition").value, 10);
        const status = $("#adminStatus").value || null;
        await api.adminUpdate(found.card.id, key, { remaining, position, status });
        toast("已更新：" + code);
        await load();
      } catch (e) { toast(e.message, true); }
    });
    $("#adminReseed").addEventListener("click", async () => {
      const key = localStorage.getItem(ADMIN_KEY) || $("#adminKeyInput").value.trim();
      try {
        await api.adminReseed(key);
        toast("顺位已重排为 1..N");
        await load();
      } catch (e) { toast(e.message, true); }
    });

    // 反馈
    $("#feedbackClose").addEventListener("click", () => ($("#feedbackModal").hidden = true));
    $("#feedbackCancel").addEventListener("click", () => ($("#feedbackModal").hidden = true));
    $("#feedbackModal").addEventListener("click", (e) => {
      if (e.target.id === "feedbackModal") $("#feedbackModal").hidden = true;
    });
    $("#feedbackSubmit").addEventListener("click", async () => {
      if (!state.feedbackTarget) return;
      const err = $("#feedbackError");
      err.hidden = true;
      try {
        await api.feedback(state.feedbackTarget.id, $("#feedbackReason").value, $("#feedbackNote").value.trim());
        $("#feedbackModal").hidden = true;
        $("#feedbackNote").value = "";
        toast("反馈已提交，谢谢");
      } catch (e) { err.textContent = e.message; err.hidden = false; }
    });

    document.addEventListener("visibilitychange", () => { if (!document.hidden) load(); });
    setInterval(() => { if (!document.hidden) load(); }, 20000);
  }

  function openFeedback(card) {
    state.feedbackTarget = card;
    $("#feedbackError").hidden = true;
    $("#feedbackModal").hidden = false;
  }

  function openAdmin() {
    const key = localStorage.getItem(ADMIN_KEY);
    $("#adminKeyInput").value = key || "";
    $("#adminPanel").hidden = !key;
    $("#adminError").hidden = true;
    $("#adminModal").hidden = false;
    if (key) {
      api.adminVerify(key)
        .then(() => { $("#adminPanel").hidden = false; })
        .catch(() => { $("#adminPanel").hidden = true; });
    }
  }

  /* ------------------------------------------------------------ 启动 */

  fillSpots();
  wire();
  $("#shareTip").textContent = MODE === "demo" ? "演示模式 · 仅本机可见" : "每人限 " + CFG.maxPublish + " 条";
  load();
})();
