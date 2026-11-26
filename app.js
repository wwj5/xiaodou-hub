/* 小豆邀请码互助站 · 前端逻辑（揭晓制 / 蓝色卡片式）
 * remote —— Supabase：列表永不含明文，只有 reveal_code 才出码
 * demo   —— 未配置时用 localStorage，语义一致
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
  const MINE_KEY = "xd:mymask";
  const DEMO_KEY = "xd:demo:v2";

  /* ---------------------------------------------------------- 工具 */

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
    const d = (Date.now() - t) / 1000;
    if (d < 60) return "刚刚";
    if (d < 3600) return Math.floor(d / 60) + " 分钟前";
    if (d < 86400) return Math.floor(d / 3600) + " 小时前";
    return Math.floor(d / 86400) + " 天前";
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
      setTimeout(() => { el.hidden = true; }, 250);
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

  const mine = {
    all() {
      try { return JSON.parse(localStorage.getItem(MINE_KEY) || "{}"); } catch (e) { return {}; }
    },
    has(id) { return !!this.all()[id]; },
    get(id) { return this.all()[id] || null; },
    add(id, code) {
      const m = this.all();
      m[id] = { code, at: new Date().toISOString() };
      const keys = Object.keys(m).sort((a, b) => (m[a].at < m[b].at ? 1 : -1));
      const out = {};
      keys.slice(0, 50).forEach((k) => { out[k] = m[k]; });
      localStorage.setItem(MINE_KEY, JSON.stringify(out));
    },
  };

  /* ---------------------------------------------------------- 远端 */

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
    if (!res.ok) throw fail((data && (data.message || data.hint)) || "请求失败（HTTP " + res.status + "）");
    return data;
  }

  /* ---------------------------------------------------------- 演示后端 */

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
            { id: "seed-3", code: "EXTRA333", status: "used", totalSpots: 1, remainingSpots: 0,
              claimedCount: 1, queueRank: 3, createdAt: now, creator: "seed2" },
          ],
          reveals: {},
          reports: {},
          seq: 3,
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
    card(c) {
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
      const used = rec && rec.date === beijingDate() ? rec.n : 0;
      return { remaining: Math.max(0, CFG.dailyReveals - used), limit: CFG.dailyReveals, resetAt: "北京时间 00:00" };
    },
    async list(status, q, token) {
      const s = this.read();
      const norm = normalizeCode(q);
      let rows = s.codes.slice();
      if (status === "available") rows = rows.filter((c) => c.status === "available");
      else if (status === "used") rows = rows.filter((c) => c.status !== "available");
      if (norm) rows = rows.filter((c) => c.code.includes(norm));
      rows.sort((a, b) => (status === "used" ? b.claimedCount - a.claimedCount : a.queueRank - b.queueRank));
      return { ok: true, cards: rows.map((c) => this.card(c)), stats: this.stats(s), quota: this.quota(token, s) };
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
        remainingSpots: spots, claimedCount: 0, queueRank: rank,
        createdAt: new Date().toISOString(), creator: token,
      };
      s.seq += 1;
      s.codes.push(row);
      this.write(s);
      return { ok: true, card: this.card(row), stats: this.stats(s) };
    },
    async reveal(id, token) {
      const s = this.read();
      const rec = s.reveals[token];
      const used = rec && rec.date === beijingDate() ? rec.n : 0;
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
      s.reveals[token] = { date: beijingDate(), n: used + 1 };
      this.write(s);
      return {
        ok: true,
        code: row.code,
        card: { ...this.card(row), code: row.code },
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

  /* ---------------------------------------------------------- API */

  const api = {
    list(status, q) {
      return MODE === "remote"
        ? rpc("list_codes", { p_status: status, p_query: q || "", p_limit: 500, p_offset: 0, p_token: visitorToken() })
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
    adminVerify(key) { return MODE === "remote" ? rpc("admin_verify", { p_key: key }) : demo.admin(); },
    adminFind(code, key) { return MODE === "remote" ? rpc("admin_find", { p_code: code, p_key: key }) : demo.admin(); },
    adminUpdate(id, key, p) {
      return MODE === "remote"
        ? rpc("admin_update", { p_id: id, p_key: key, p_remaining: p.remaining, p_position: p.position, p_status: p.status })
        : demo.admin();
    },
    adminReseed(key) { return MODE === "remote" ? rpc("admin_reseed", { p_key: key }) : demo.admin(); },
  };

  /* ---------------------------------------------------------- 状态 */

  const state = {
    avail: [],
    used: [],
    stats: { issued: 0, available: 0, revealed: 0, revealedCount: 0 },
    quota: { remaining: CFG.dailyReveals, limit: CFG.dailyReveals, resetAt: "北京时间 00:00" },
    busy: false,
    feedbackTarget: null,
  };

  /* ---------------------------------------------------------- 渲染 */

  function renderStats() {
    $("#statIssued").textContent = state.stats.issued ?? "—";
    $("#statAvailable").textContent = state.stats.available ?? "—";
  }

  function renderQuota() {
    const q = state.quota || {};
    const limit = q.limit || CFG.dailyReveals;
    const left = Math.max(0, q.remaining == null ? limit : q.remaining);
    $("#quotaText").textContent = left + " / " + limit;
    const bars = [];
    for (let i = 0; i < limit; i += 1) bars.push('<i class="' + (i < left ? "on" : "") + '"></i>');
    $("#quotaBars").innerHTML = bars.join("");
  }

  function renderEmpty(show) {
    $("#emptyCard").hidden = !show;
  }

  function renderGrid() {
    const list = $("#list");
    renderEmpty(state.avail.length === 0);
    if (!state.avail.length) { list.innerHTML = ""; return; }

    list.innerHTML = state.avail.map((c) => {
      const got = mine.get(c.id);
      const cls = got ? " mine" : "";
      const codeCls = got ? "cc-code revealed" : "cc-code";
      const tag = got ? '<span class="cc-tag done">已领取</span>' : '<span class="cc-tag">可揭晓</span>';
      const actions = got
        ? '<button class="mini-btn solid" data-act="copy" data-id="' + esc(c.id) + '">复制</button>'
        : '<button class="mini-btn solid" data-act="reveal" data-id="' + esc(c.id) + '">点击揭晓</button>';
      return (
        '<article class="code-card' + cls + '">' +
          '<div class="cc-top"><span class="cc-rank">#' + c.queueRank + "</span>" + tag + "</div>" +
          '<div class="' + codeCls + '">' + esc(got ? got.code : c.mask) + "</div>" +
          '<div class="cc-meta"><span>剩余 ' + c.remainingSpots + " / " + c.totalSpots + " 次</span>" +
            "<span>已揭 " + c.claimedCount + " 次</span><span>" + timeAgo(c.createdAt) + "</span></div>" +
          '<div class="cc-actions">' + actions +
            '<button class="mini-btn ghost" data-act="feedback" data-id="' + esc(c.id) + '">反馈</button></div>' +
        "</article>"
      );
    }).join("");
  }

  function renderHistory() {
    const box = $("#historyList");
    if (!state.used.length) {
      box.innerHTML = '<div class="history-empty">还没有人揭晓过。等你放第一个码进来。</div>';
      return;
    }
    box.innerHTML = state.used.slice(0, 20).map((c) => {
      const got = mine.get(c.id);
      return (
        '<div class="hrow">' +
          '<span class="htag">已领取</span>' +
          '<span class="hcode' + (got ? " revealed" : "") + '">' + esc(got ? got.code : c.mask) + "</span>" +
          '<span class="hmeta">' + c.claimedCount + " 次揭晓 · " + timeAgo(c.createdAt) + "</span>" +
          (got ? '<button class="mini-btn" data-act="copy" data-id="' + esc(c.id) + '">复制</button>' : "") +
        "</div>"
      );
    }).join("");
    $("#historyNote").textContent = "共 " + state.used.length + " 条";
  }

  function renderAll() {
    renderStats();
    renderQuota();
    renderGrid();
    renderHistory();
  }

  /* ---------------------------------------------------------- 加载 */

  let loading = false;
  async function load() {
    if (loading) return;
    loading = true;
    try {
      const [availRes, usedRes] = await Promise.all([api.list("available"), api.list("used")]);
      state.avail = availRes.cards || [];
      state.used = usedRes.cards || [];
      state.stats = availRes.stats || state.stats;
      if (availRes.quota) state.quota = availRes.quota;
      renderAll();
    } catch (e) {
      $("#list").innerHTML = '<div class="history-empty">加载失败：' + esc(e.message) + "</div>";
      $("#emptyCard").hidden = true;
    } finally {
      loading = false;
    }
  }

  /* ---------------------------------------------------------- 交互 */

  function fillSpots() {
    const opts = [1, 2, 3, 5, 10, 20, 30].filter((n) => n <= CFG.maxSpots);
    $("#spotsInput").innerHTML = opts
      .map((n) => '<option value="' + n + '"' + (n === 3 ? " selected" : "") + ">" + n + " 次</option>")
      .join("");
  }

  async function doReveal(id) {
    if (state.busy) return;
    state.busy = true;
    try {
      const res = await api.reveal(id);
      mine.add(id, res.code);
      if (res.quotaRemaining != null) state.quota = { ...state.quota, remaining: res.quotaRemaining };
      const ok = await copyText(res.code);
      toast("揭晓成功：" + res.code + (ok ? "，已复制" : "，请手动复制"));
      await load();
    } catch (e) {
      toast(e.message, true);
    } finally {
      state.busy = false;
    }
  }

  function wire() {
    $("#shareJump").addEventListener("click", () => {
      $("#sharePanel").scrollIntoView({ behavior: "smooth", block: "center" });
      setTimeout(() => $("#codeInput").focus(), 320);
    });

    $("#quotaHintBtn").addEventListener("click", () => {
      const q = state.quota || {};
      toast("每人每天 " + (q.limit || CFG.dailyReveals) + " 次揭晓，" + (q.resetAt || "北京时间 00:00") + " 重置");
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
        await load();
      } catch (err) {
        errBox.textContent = err.message;
        errBox.hidden = false;
      } finally {
        btn.disabled = false;
        btn.textContent = "立即分享";
      }
    });

    const onCardAction = async (e) => {
      const btn = e.target.closest("button[data-act]");
      if (!btn) return;
      const id = btn.dataset.id;
      if (btn.dataset.act === "reveal") return doReveal(id);
      if (btn.dataset.act === "copy") {
        const got = mine.get(id);
        if (!got) return;
        const ok = await copyText(got.code);
        toast(ok ? "已复制：" + got.code : "复制失败，请手动选中", !ok);
        return;
      }
      if (btn.dataset.act === "feedback") {
        const card = state.avail.find((c) => String(c.id) === id) ||
                     state.used.find((c) => String(c.id) === id);
        if (!card) return;
        state.feedbackTarget = card;
        $("#feedbackError").hidden = true;
        $("#feedbackModal").hidden = false;
      }
    };
    $("#list").addEventListener("click", onCardAction);
    $("#historyList").addEventListener("click", onCardAction);

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

  /* ---------------------------------------------------------- 启动 */

  fillSpots();
  wire();
  load();
})();
