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
      codeMinLen: 6,
      codeMaxLen: 6,
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
  const RELAY_KEY = "xd:relay";
  const DEMO_KEY = "xd:demo:v2";

  /* ---------------------------------------------------------- 工具 */

  function esc(str) {
    return String(str == null ? "" : str).replace(/[&<>"']/g, (c) => (
      { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
    ));
  }

  function shortHash(str) {
    let h = 2166136261;
    for (let i = 0; i < str.length; i += 1) {
      h ^= str.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    return (h >>> 0).toString(36);
  }

  /** 轻量设备指纹：清掉 localStorage 也还是同一个人，避免"清缓存换新身份"无限领免费码 */
  function fingerprint() {
    let canvas = "";
    try {
      const c = document.createElement("canvas");
      c.width = 140;
      c.height = 44;
      const ctx = c.getContext("2d");
      ctx.textBaseline = "top";
      ctx.fillStyle = "#f60";
      ctx.fillRect(0, 0, 140, 44);
      ctx.fillStyle = "#06c";
      ctx.font = "15px Arial";
      ctx.fillText("xiaodou-hub-fp", 5, 8);
      ctx.fillStyle = "rgba(102,204,0,.65)";
      ctx.fillText("xiaodou-hub-fp", 7, 22);
      canvas = c.toDataURL().slice(-90);
    } catch (e) {
      canvas = "";
    }
    const parts = [
      navigator.userAgent,
      navigator.language,
      (navigator.languages || []).join(","),
      (Intl.DateTimeFormat().resolvedOptions().timeZone || ""),
      screen.width + "x" + screen.height + "x" + screen.colorDepth,
      window.devicePixelRatio || 1,
      navigator.hardwareConcurrency || "",
      navigator.deviceMemory || "",
      canvas,
    ].join("|");
    return "fp" + shortHash(parts);
  }

  function visitorToken() {
    let t = null;
    try { t = localStorage.getItem(TOKEN_KEY); } catch (e) { t = null; }
    if (!t || t.slice(0, 2) !== "fp") {
      t = fingerprint();
      try { localStorage.setItem(TOKEN_KEY, t); } catch (e) {}
    }
    return t;
  }

  function normalizeCode(raw) {
    return String(raw || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
  }

  const CODE_WORDS = ["OPENAI", "CLOUD", "GOOGLE", "GITHUB", "DOUBAO", "PYTHON",
                      "MOBILE", "SERVER", "WINDOW", "SYSTEM", "PUBLIC", "MASTER", "SECRET"];

  /** 校验一枚码是否符合本站收录规则；返回错误文案，合法则返回 "" */
  function codeProblem(norm) {
    const c = normalizeCode(norm);
    if (c.length !== 6) return "邀请码必须是 6 位，你填的是 " + c.length + " 位";
    if (!/[A-Z]/.test(c) || !/[0-9]/.test(c)) return "邀请码必须字母和数字都有；纯字母、纯数字的码本站不收";
    if (/[A-Z]{3}/.test(c)) return "邀请码里不能有 3 个字母连在一起（像乱填的），本站不收";
    if (/[0-9]{3}/.test(c)) return "邀请码里不能有 3 个数字连在一起（像乱填的），本站不收";
    if (CODE_WORDS.indexOf(c) >= 0) return "这看着是英文单词，不是邀请码，本站不收";
    if (/(91|78|13|27)/.test(c)) return "邀请码里带了不合适的数字（91 / 78 / 13 / 27），本站不收";
    return "";
  }

  /** 从官方邀请链接里把邀请码捞出来；也容忍「邀请码：ABCD」这类文本 */
  function extractCode(input) {
    const text = String(input || "").trim();
    if (!text) return "";

    const paramKeys = ["invite_code", "inviteCode", "invitation_code", "icode", "code", "invite"];

    // 1) 纯链接（或链接里带参数）
    const urlMatch = text.match(/https?:\/\/[^\s"'<>]+/i);
    if (urlMatch) {
      const raw = urlMatch[0];
      try {
        const url = new URL(raw);
        for (const k of paramKeys) {
          const v = url.searchParams.get(k);
          if (v) {
            const c = normalizeCode(v);
            if (c.length >= CFG.codeMinLen) return c;
          }
        }
        // 路径里形如 /invite/ABCD1234 或 /i/ABCD1234
        const segs = url.pathname.split("/").filter(Boolean);
        for (let i = segs.length - 1; i >= 0; i -= 1) {
          const c = normalizeCode(segs[i]);
          if (/^[A-Za-z0-9]{6,32}$/.test(segs[i]) && c.length >= CFG.codeMinLen) return c;
        }
      } catch (e) { /* 不是合法 URL，落到下面的文本解析 */ }
      // 链接里没解析出参数，再看 ?xxx=CODE 这种土办法
      const q = raw.match(/[?&](?:invite_?code|code|icode|invite)=([^&#\s]+)/i);
      if (q) {
        const c = normalizeCode(decodeURIComponent(q[1]));
        if (c.length >= CFG.codeMinLen) return c;
      }
      return "";
    }

    // 2) 文本里带「邀请码」字样
    const labeled = text.match(/邀请码[^A-Za-z0-9]{0,6}([A-Za-z0-9]{6})/);
    if (labeled) return normalizeCode(labeled[1]);

    // 3) 干脆就是一串码
    return normalizeCode(text);
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

  /* 接力：接过别人的码，就该把自己的码放回来。
     远端模式下待还数量以服务端为准（本地只记录演示模式与一次性的临时提示）。 */
  function relayPending() {
    if (state.relay) return Math.max(0, Number(state.relay.pending) || 0);
    if (MODE === "remote") return 0;
    return relay.state().pending || 0;
  }

  function relayBump(delta) {
    if (state.relay) {
      state.relay.taken = Math.max(0, (Number(state.relay.taken) || 0) + Math.max(0, delta));
      state.relay.returned = Math.max(0, (Number(state.relay.returned) || 0) + Math.max(0, -delta));
      state.relay.pending = Math.max(0, state.relay.taken - state.relay.returned);
    } else if (MODE !== "remote") {
      if (delta > 0) relay.take(); else relay.done();
    }
  }

  const relay = {
    state() {
      try { return JSON.parse(localStorage.getItem(RELAY_KEY) || '{"pending":0}'); } catch (e) { return { pending: 0 }; }
    },
    save(s) { localStorage.setItem(RELAY_KEY, JSON.stringify(s)); },
    take() {
      const s = this.state();
      s.pending = (s.pending || 0) + 1;
      this.save(s);
      return s.pending;
    },
    done() { this.save({ pending: 0 }); },
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
        fresh: Date.now() - new Date(c.createdAt).getTime() < 15 * 60 * 1000,
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
      rows.sort((a, b) => (status === "used"
        ? b.claimedCount - a.claimedCount
        : new Date(b.createdAt) - new Date(a.createdAt)));
      return { ok: true, cards: rows.map((c) => this.card(c)), stats: this.stats(s), quota: this.quota(token, s) };
    },
    async publish(code, spots, token) {
      const s = this.read();
      const norm = normalizeCode(code);
      const bad = codeProblem(norm);
      if (bad) throw fail(bad);
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
      s.revealTotal = s.revealTotal || {};
      const rec = s.reveals[token];
      const used = rec && rec.date === beijingDate() ? rec.n : 0;
      if (used >= CFG.dailyReveals) {
        throw fail("今天的揭晓次数用完了（每人每天 " + CFG.dailyReveals + " 次，北京时间 00:00 重置）");
      }
      const total = s.revealTotal[token] || 0;
      const published = s.codes.filter((c) => c.creator === token).length;
      if (total >= published + 1) {
        throw fail("接力规则：你已经接过 " + total + " 个码，只放回 " + published + " 个。先把自己的码分享进来，才能继续揭晓");
      }
      const row = s.codes.find((c) => c.id === id);
      if (!row) throw fail("这个邀请码不存在了");
      if (row.status !== "available" || row.remainingSpots <= 0) throw fail("这个邀请码已经被别人揭晓了");
      if (s.reports[token + "|" + id]) throw fail("你已经揭晓过这个码了");
      row.remainingSpots -= 1;
      row.claimedCount += 1;
      if (row.remainingSpots <= 0) row.status = "used";
      s.reports[token + "|" + id] = true;
      s.revealTotal[token] = total + 1;
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
  };

  /* ---------------------------------------------------------- 状态 */

  const state = {
    avail: [],
    used: [],
    stats: { issued: 0, available: 0, revealed: 0, revealedCount: 0 },
    quota: { remaining: CFG.dailyReveals, limit: CFG.dailyReveals, resetAt: "北京时间 00:00" },
    relay: null,
    busy: false,
    feedbackTarget: null,
  };

  /* ---------------------------------------------------------- 渲染 */

  function renderStats() {
    $("#statIssued").textContent = state.stats.issued ?? "—";
    $("#statAvailable").textContent = state.stats.available ?? "—";
    // 只放聚合数，不点名、不带任何可定位信息
    const un = Number(state.stats.unreturned || 0);
    const note = $("#unreturnedNote");
    if (note) {
      note.hidden = un <= 0;
      note.textContent = un > 0 ? "（有 " + un + " 人拿了码还没放回来）" : "";
    }
  }

  function renderEmpty(show) {
    $("#emptyCard").hidden = !show;
  }

  function renderRelay() {
    const pending = relayPending();
    const strip = $("#relayStrip");
    if (!strip) return;
    const voided = Number((state.relay && state.relay.voided) || 0);
    const voidedTip = voided > 0
      ? "注意：你放回的 " + voided + " 个码被下架了（下架/无效的码不算回填），欠的还得再放一个能用的。"
      : "";
    strip.hidden = pending <= 0 && !voidedTip;
    if (pending > 0) {
      const mins = Number(state.stats && state.stats.graceMinutes);
      const tail = mins > 0
        ? "超过 " + mins + " 分钟没放回来，这台设备会被自动限制，放回后自动解除。"
        : "先把你的邀请码放回来，才能接下一个。";
      $("#relayText").textContent =
        "你从池子里接过 " + pending + " 个码还没还。" + tail + (voidedTip ? " " + voidedTip : "");
      strip.hidden = false;
    } else if (voidedTip) {
      $("#relayText").textContent = voidedTip;
    } else if (state.relay && state.relay.blocked) {
      $("#relayText").textContent = "这台设备已被限制揭晓：先把自己的邀请码放回来，放回后自动解除。";
      strip.hidden = false;
    }
  }

  function renderGrid() {
    const list = $("#list");
    renderEmpty(state.avail.length === 0);
    if (!state.avail.length) { list.innerHTML = ""; return; }

    const blocked = !!(state.relay && state.relay.blocked);
    list.innerHTML = state.avail.map((c, i) => {
      const got = mine.get(c.id);
      const cls = (got ? " mine" : "") + (c.fresh ? " fresh" : "");
      const codeCls = got ? "cc-code revealed" : "cc-code";
      const freshTag = c.fresh ? '<span class="cc-tag fresh">实时新码</span>' : "";
      const tag = got ? '<span class="cc-tag done">已领取</span>' : freshTag + '<span class="cc-tag">可揭晓</span>';
      const actions = got
        ? '<button class="mini-btn solid" data-act="copy" data-id="' + esc(c.id) + '">复制</button>'
        : (blocked
          ? '<button class="mini-btn ghost" type="button" disabled title="先把自己的邀请码放回来">先回填自己的码</button>'
          : '<button class="mini-btn solid" data-act="reveal" data-id="' + esc(c.id) + '">点击揭晓</button>');
      return (
        '<article class="code-card' + cls + '">' +
          '<div class="cc-top"><span class="cc-rank">#' + (i + 1) + "</span>" + tag + "</div>" +
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
    renderRelay();
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
      if (availRes.relay) state.relay = availRes.relay;
      if (MODE === "remote") localStorage.removeItem(RELAY_KEY);
      renderAll();
    } catch (e) {
      $("#list").innerHTML = '<div class="history-empty">加载失败：' + esc(e.message) + "</div>";
      $("#emptyCard").hidden = true;
    } finally {
      loading = false;
    }
  }

  /* ---------------------------------------------------------- 交互 */

  async function doReveal(id) {
    if (state.busy) return;
    state.busy = true;
    try {
      const res = await api.reveal(id);
      mine.add(id, res.code);
      if (res.quotaRemaining != null) state.quota = { ...state.quota, remaining: res.quotaRemaining };
      const ok = await copyText(res.code);
      toast("揭晓成功：" + res.code + (ok ? "，已复制" : "，请手动复制"));
      relayBump(+1);
      renderRelay();
      $("#relayCode").textContent = res.code;
      const mins2 = Number(state.stats && state.stats.graceMinutes);
      const note = $("#relayNote");
      if (note) {
        note.innerHTML = mins2 > 0
          ? "免费纯接力：码是别人接给你的，不是卖的。请在 <b>" + mins2 + " 分钟</b>内把自己的邀请码放回池子，"
            + "超时这台设备会被自动限制（放回后立即解除）。"
          : "免费纯接力：码是别人接给你的，不是卖的。等你自己的邀请码下来了，也放回池子里，下一个人才能接得上。";
      }
      $("#relayModal").hidden = false;
      await load();
    } catch (e) {
      toast(e.message, true);
    } finally {
      state.busy = false;
    }
  }

  function openShare() {
    $("#relayModal").hidden = true;
    $("#shareError").hidden = true;
    $("#shareModal").hidden = false;
    setTimeout(() => $("#codeInput").focus(), 120);
  }

  function closeShare() {
    $("#shareModal").hidden = true;
  }

  function wire() {
    $("#shareJump").addEventListener("click", openShare);
    $("#emptyShare").addEventListener("click", openShare);
    $("#relayShare").addEventListener("click", openShare);
    $("#relayNow").addEventListener("click", openShare);
    $("#relayLater").addEventListener("click", () => ($("#relayModal").hidden = true));
    $("#relayClose").addEventListener("click", () => ($("#relayModal").hidden = true));
    $("#relayModal").addEventListener("click", (e) => {
      if (e.target.id === "relayModal") $("#relayModal").hidden = true;
    });
    $("#shareClose").addEventListener("click", closeShare);
    $("#shareCancel").addEventListener("click", closeShare);
    $("#shareModal").addEventListener("click", (e) => {
      if (e.target.id === "shareModal") closeShare();
    });

    $("#refreshBtn").addEventListener("click", (e) => {
      const btn = e.currentTarget;
      btn.classList.add("spin");
      setTimeout(() => btn.classList.remove("spin"), 500);
      load();
    });

    $("#shareForm").addEventListener("submit", async (e) => {
      e.preventDefault();
      const errBox = $("#shareError");
      errBox.hidden = true;
      const raw = $("#codeInput").value;
      const code = extractCode(raw);
      if (!code) {
        errBox.textContent = "没从这段内容里解析出邀请码，检查一下链接是否完整";
        errBox.hidden = false;
        return;
      }
      const bad = codeProblem(code);
      if (bad) {
        errBox.textContent = bad;
        errBox.hidden = false;
        return;
      }
      const btn = $("#shareSubmit");
      btn.disabled = true;
      btn.textContent = "提交中…";
      try {
        await api.publish(code, 1);
        $("#codeInput").value = "";
        closeShare();
        relayBump(-1);
        renderRelay();
        toast("接力完成，已放进队列：" + code);
        await load();
      } catch (err) {
        errBox.textContent = err.message;
        errBox.hidden = false;
      } finally {
        btn.disabled = false;
        btn.textContent = "提交邀请码";
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
        const r = await api.feedback(state.feedbackTarget.id, $("#feedbackReason").value, $("#feedbackNote").value.trim());
        $("#feedbackModal").hidden = true;
        $("#feedbackNote").value = "";
        toast(r && r.autoClosed ? "已收到，这个码举报够了，先摘下等核验" : "反馈已提交，谢谢");
        await load();
      } catch (e) { err.textContent = e.message; err.hidden = false; }
    });

    document.addEventListener("visibilitychange", () => { if (!document.hidden) load(); });
    setInterval(() => { if (!document.hidden) load(); }, 20000);
  }

  /* ---------------------------------------------------------- 公告 */

  const NOTICE_KEY = "xd:notice:date";

  function noticeSeenToday() {
    try { return localStorage.getItem(NOTICE_KEY) === beijingDate(); } catch (e) { return false; }
  }

  function showNotice() {
    if (noticeSeenToday()) return;
    const box = $("#noticeModal");
    if (!box) return;
    box.hidden = false;
  }

  function closeNotice() {
    const box = $("#noticeModal");
    if (!box) return;
    if ($("#noticeToday") && $("#noticeToday").checked) {
      try { localStorage.setItem(NOTICE_KEY, beijingDate()); } catch (e) { /* 忽略隐私模式写入失败 */ }
    }
    box.hidden = true;
  }

  /* ---------------------------------------------------------- 启动 */

  wire();

  $("#noticeOk").addEventListener("click", closeNotice);
  $("#noticeClose").addEventListener("click", closeNotice);
  $("#noticeGo").addEventListener("click", () => {
    closeNotice();
    openShare();
  });
  $("#noticeModal").addEventListener("click", (e) => {
    if (e.target.id === "noticeModal") closeNotice();
  });
  showNotice();

  /* ---------------------------------------------------------- 说明弹窗 */

  function openHow() {
    const box = $("#howModal");
    if (box) box.hidden = false;
  }

  function closeHow() {
    const box = $("#howModal");
    if (box) box.hidden = true;
  }

  $("#howOpen").addEventListener("click", openHow);
  $("#howOpenTop").addEventListener("click", (e) => { e.preventDefault(); openHow(); });
  $("#footHow").addEventListener("click", (e) => { e.preventDefault(); openHow(); });
  $("#footDisclaimer").addEventListener("click", (e) => { e.preventDefault(); openHow(); });
  $("#emptyHow").addEventListener("click", openHow);
  $("#noticeHow").addEventListener("click", (e) => {
    e.preventDefault();
    closeNotice();
    openHow();
  });
  $("#howClose").addEventListener("click", closeHow);
  $("#howOk").addEventListener("click", closeHow);
  $("#howGo").addEventListener("click", () => {
    closeHow();
    openShare();
  });
  $("#howModal").addEventListener("click", (e) => {
    if (e.target.id === "howModal") closeHow();
  });

  load();
})();
