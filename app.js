/* 小豆邀请码互助站 · 前端逻辑
 * 两种后端模式：
 *   1) remote —— 配置了 Supabase URL + anon key，数据全站共享（正式用法）
 *   2) demo   —— 没配置时自动降级为浏览器 localStorage，只在你自己这一个浏览器里可见
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
      maxClaims: 2,
      maxPublish: 1,
    },
    window.HUB_CONFIG || {}
  );

  const MODE = CFG.supabaseUrl && CFG.supabaseKey ? "remote" : "demo";

  const $ = (sel) => document.querySelector(sel);
  const tokenKey = "xd:visitor";
  const adminKeyStore = "xd:admin";
  const demoStore = "xd:demo:v1";

  /* ------------------------------------------------------------ 通用工具 */

  function esc(str) {
    return String(str == null ? "" : str).replace(/[&<>"']/g, (c) => (
      { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
    ));
  }

  function visitorToken() {
    let t = localStorage.getItem(tokenKey);
    if (!t) {
      t = (crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(36).slice(2) + Date.now()) + Date.now().toString(36);
      localStorage.setItem(tokenKey, t);
    }
    return t;
  }

  function normalizeCode(raw) {
    return String(raw || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
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
    }, 2200);
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
    const err = new Error(msg);
    err.isApi = true;
    return err;
  }

  /* ------------------------------------------------------------ 远端后端（Supabase） */

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
      const msg = (data && (data.message || data.hint)) || "请求失败（HTTP " + res.status + "）";
      throw fail(msg);
    }
    return data;
  }

  /* ------------------------------------------------------------ 演示后端（localStorage） */

  const demo = {
    read() {
      let raw = localStorage.getItem(demoStore);
      if (!raw) {
        const now = new Date().toISOString();
        const seed = [
          { id: "seed-3", code: "XD2026A", status: "available", totalSpots: 5, remainingSpots: 3, claimedCount: 2, queueRank: 1, createdAt: now },
          { id: "seed-2", code: "XIAODOU7", status: "used", totalSpots: 2, remainingSpots: 0, claimedCount: 2, queueRank: 2, createdAt: now },
        ];
        raw = JSON.stringify({ codes: seed, claims: {}, reports: [], seq: 3 });
        localStorage.setItem(demoStore, raw);
      }
      return JSON.parse(raw);
    },
    write(state) {
      localStorage.setItem(demoStore, JSON.stringify(state));
    },
    stats(state) {
      const available = state.codes.filter((c) => c.status === "available");
      return {
        issued: state.codes.length,
        available: available.length,
        used: state.codes.length - available.length,
        availableSpots: available.reduce((s, c) => s + c.remainingSpots, 0),
      };
    },
    card(c, token) {
      return {
        id: c.id,
        code: c.code,
        status: c.status,
        totalSpots: c.totalSpots,
        remainingSpots: c.remainingSpots,
        claimedCount: c.claimedCount,
        queueRank: c.queueRank,
        createdAt: c.createdAt,
        mine: c.creator === token,
      };
    },
    async list(status, q, token) {
      const state = this.read();
      const norm = normalizeCode(q);
      let rows = state.codes.slice();
      if (status === "available") rows = rows.filter((c) => c.status === "available");
      else if (status === "used") rows = rows.filter((c) => c.status !== "available");
      if (norm) rows = rows.filter((c) => c.code.includes(norm));
      rows.sort((a, b) => a.queueRank - b.queueRank);
      return { ok: true, cards: rows.map((c) => this.card(c, token)), stats: this.stats(state) };
    },
    async codesOfVisitor(token) {
      const state = this.read();
      const used = state.claims[token] || 0;
      return {
        ok: true,
        quotaRemaining: Math.max(0, CFG.maxClaims - used),
        myCodes: state.codes.filter((c) => c.creator === token && c.status === "available").map((c) => this.card(c, token)),
      };
    },
    async publish(code, spots, token) {
      const state = this.read();
      const norm = normalizeCode(code);
      if (norm.length < CFG.codeMinLen || norm.length > CFG.codeMaxLen) throw fail("邀请码长度需为 " + CFG.codeMinLen + "–" + CFG.codeMaxLen + " 位字母或数字");
      if (spots < 1 || spots > CFG.maxSpots) throw fail("剩余次数必须是 1–30 的整数");
      if (state.codes.some((c) => c.code === norm)) throw fail("该邀请码已经在池里了");
      if (state.codes.some((c) => c.creator === token && c.status === "available")) throw fail("同一个人最多保留 1 个可用邀请码");
      const rank = state.codes.reduce((m, c) => Math.max(m, c.queueRank), 0) + 1;
      const row = {
        id: "demo-" + (state.seq + 1),
        code: norm,
        status: "available",
        totalSpots: spots,
        remainingSpots: spots,
        claimedCount: 0,
        queueRank: rank,
        creator: token,
        createdAt: new Date().toISOString(),
      };
      state.seq += 1;
      state.codes.push(row);
      this.write(state);
      return { ok: true, card: this.card(row, token), stats: this.stats(state) };
    },
    async claim(id, token) {
      const state = this.read();
      const row = state.codes.find((c) => c.id === id);
      if (!row) throw fail("这个邀请码不存在了");
      if (row.status !== "available" || row.remainingSpots <= 0) throw fail("这个邀请码已经用完了");
      const used = state.claims[token] || 0;
      if (used >= CFG.maxClaims) throw fail("每人最多领取 " + CFG.maxClaims + " 个邀请码，你已经用完了");
      const claimedKey = token + "|" + id;
      if (state.reports.indexOf(claimedKey) >= 0) throw fail("你已经领取过这个码了");
      row.remainingSpots -= 1;
      row.claimedCount += 1;
      if (row.remainingSpots <= 0) row.status = "used";
      state.claims[token] = used + 1;
      state.reports.push(claimedKey);
      this.write(state);
      return {
        ok: true,
        code: row.code,
        card: this.card(row, token),
        stats: this.stats(state),
        quotaRemaining: Math.max(0, CFG.maxClaims - used - 1),
      };
    },
    async feedback(id, reason, note, token) {
      const state = this.read();
      const row = state.codes.find((c) => c.id === id);
      if (!row) throw fail("邀请码不存在");
      const key = token + "|" + id + "|" + reason;
      state.feedbacks = state.feedbacks || {};
      if (state.feedbacks[key]) throw fail("你已经反馈过同样的原因了");
      state.feedbacks[key] = { reason, note: String(note || "").slice(0, 300), at: new Date().toISOString() };
      this.write(state);
      return { ok: true };
    },
    async adminVerify() {
      throw fail("演示模式没有真正的管理密钥：配置 Supabase 后才能管理全站");
    },
    async adminFind() {
      throw fail("演示模式不支持管理");
    },
    async adminUpdate() {
      throw fail("演示模式不支持管理");
    },
    async adminReseed() {
      throw fail("演示模式不支持管理");
    },
  };

  /* ------------------------------------------------------------ 统一 API */

  const api = {
    list(status, q) {
      if (MODE === "remote") {
        return rpc("list_codes", {
          p_status: status,
          p_query: q,
          p_limit: 500,
          p_offset: 0,
          p_token: visitorToken(),
        });
      }
      return demo.list(status, q, visitorToken());
    },
    codesOfVisitor() {
      if (MODE === "remote") return rpc("codes_of_visitor", { p_token: visitorToken() });
      return demo.codesOfVisitor(visitorToken());
    },
    publish(code, spots) {
      if (MODE === "remote") return rpc("publish_code", { p_code: code, p_spots: spots, p_token: visitorToken() });
      return demo.publish(code, spots, visitorToken());
    },
    claim(id) {
      if (MODE === "remote") return rpc("claim_code", { p_id: id, p_token: visitorToken() });
      return demo.claim(id, visitorToken());
    },
    feedback(id, reason, note) {
      if (MODE === "remote") {
        return rpc("submit_feedback", { p_id: id, p_reason: reason, p_note: note, p_token: visitorToken() });
      }
      return demo.feedback(id, reason, note, visitorToken());
    },
    adminVerify(key) {
      if (MODE === "remote") return rpc("admin_verify", { p_key: key });
      return demo.adminVerify();
    },
    adminFind(code, key) {
      if (MODE === "remote") return rpc("admin_find", { p_code: code, p_key: key });
      return demo.adminFind();
    },
    adminUpdate(id, key, payload) {
      if (MODE === "remote") {
        return rpc("admin_update", {
          p_id: id,
          p_key: key,
          p_remaining: payload.remaining,
          p_position: payload.position,
          p_status: payload.status,
        });
      }
      return demo.adminUpdate();
    },
    adminReseed(key) {
      if (MODE === "remote") return rpc("admin_reseed", { p_key: key });
      return demo.adminReseed();
    },
  };

  /* ------------------------------------------------------------ 状态 */

  const state = {
    filter: "available",
    query: "",
    cards: [],
    stats: { issued: 0, available: 0, used: 0, availableSpots: 0 },
    head: null,
    quota: null,
    busy: false,
  };

  /* ------------------------------------------------------------ 渲染 */

  function renderStats() {
    $("#statIssued").textContent = state.stats.issued ?? "—";
    $("#statAvailable").textContent = state.stats.available ?? "—";
    $("#statSpots").textContent = state.stats.availableSpots ?? "—";
  }

  function renderHero() {
    const dot = $("#heroDot");
    const text = $("#heroStatus");
    if (MODE === "demo") {
      dot.className = "dot warn";
      text.textContent = "演示模式：数据只在这台浏览器里，配置 Supabase 后全站共享";
    } else if (state.stats.available > 0) {
      dot.className = "dot";
      text.textContent = "已连接 · 现在有 " + state.stats.available + " 个码可以领";
    } else {
      dot.className = "dot warn";
      text.textContent = "已连接 · 暂时没有可领取的邀请码，等别人放码";
    }
  }

  function renderPassport() {
    const box = $("#passport");
    const head = state.head;
    if (!head) {
      box.hidden = true;
      return;
    }
    box.hidden = false;
    $("#passportCode").textContent = head.code;
    $("#passportRank").textContent = "顺位 #" + head.queueRank;
    $("#passportSpots").textContent = head.remainingSpots + " / " + head.totalSpots;
    $("#passportState").textContent = head.status === "available" ? "可领取" : "已用完";
    $("#passportTime").textContent = timeAgo(head.createdAt);
    $("#quotaHint").textContent = state.quota == null
      ? "每人最多领 " + CFG.maxClaims + " 个码"
      : "今日领取名额：还剩 " + state.quota + " / " + CFG.maxClaims;
    $("#passportClaim").disabled = head.status !== "available";
  }

  function renderList() {
    const list = $("#list");
    if (!state.cards.length) {
      list.innerHTML = state.query
        ? '<div class="empty">没有匹配「' + esc(state.query) + '」的邀请码</div>'
        : '<div class="empty">' + (state.filter === "available"
            ? "暂时没有可领取的邀请码，等你放第一个进来"
            : "这个分类下还没有记录") + "</div>";
      return;
    }
    list.innerHTML = state.cards.map((c) => {
      const dim = c.status === "available" ? "" : " dim";
      const pct = c.totalSpots ? Math.round((c.remainingSpots / c.totalSpots) * 100) : 0;
      const badge = c.status === "available" ? "可领取" : "已用完";
      const actions = [
        '<button class="mini-btn" data-act="copy" data-id="' + esc(c.id) + '">复制</button>',
        c.status === "available"
          ? '<button class="mini-btn solid" data-act="claim" data-id="' + esc(c.id) + '">领走一个 -1</button>'
          : "",
      ].join("");
      return (
        '<div class="row' + dim + '">' +
          '<div class="row-rank">#' + c.queueRank + "</div>" +
          '<div class="row-main">' +
            '<div class="row-code">' + esc(c.code) + "</div>" +
            '<div class="row-sub">' + badge + (c.mine ? " · 我发布的" : "") +
              " · " + timeAgo(c.createdAt) + " · 领走 " + c.claimedCount + " 次</div>" +
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
    renderList();
  }

  /* ------------------------------------------------------------ 数据加载 */

  let loading = false;
  async function load(silent) {
    if (loading) return;
    loading = true;
    try {
      const data = await api.list(state.filter, state.query);
      state.cards = data.cards || [];
      state.stats = data.stats || state.stats;
      state.head = state.cards.find((c) => c.status === "available") || null;
      if (state.filter !== "available") {
        const avail = (await api.list("available", "")).cards || [];
        state.head = avail.find((c) => c.status === "available") || null;
      }
      renderAll();
      if (!silent) {
        const quota = await api.codesOfVisitor().catch(() => null);
        if (quota && quota.quotaRemaining != null) {
          state.quota = quota.quotaRemaining;
          renderPassport();
        }
      }
    } catch (e) {
      $("#list").innerHTML = '<div class="error-state">加载失败：' + esc(e.message) + "</div>";
      $("#heroDot").className = "dot bad";
      $("#heroStatus").textContent = "连接失败：" + e.message;
      if (!silent) toast(e.message, true);
    } finally {
      loading = false;
    }
  }

  /* ------------------------------------------------------------ 事件 */

  const spotsSelect = $("#spotsInput");
  function fillSpots() {
    const opts = [1, 2, 3, 5, 10, 20, 30].filter((n) => n <= CFG.maxSpots);
    spotsSelect.innerHTML = opts.map((n) => '<option value="' + n + '"' + (n === 3 ? " selected" : "") + ">" + n + " 次</option>").join("");
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
      searchTimer = setTimeout(() => load(true), 220);
    });

    $("#refreshBtn").addEventListener("click", () => {
      toast("已刷新");
      load();
    });

    $("#shareForm").addEventListener("submit", async (e) => {
      e.preventDefault();
      const errBox = $("#shareError");
      errBox.hidden = true;
      const raw = $("#codeInput").value;
      const code = normalizeCode(raw);
      const spots = parseInt(spotsSelect.value, 10);
      if (code.length < CFG.codeMinLen || code.length > CFG.codeMaxLen) {
        errBox.textContent = "邀请码长度需为 " + CFG.codeMinLen + "–" + CFG.codeMaxLen + " 位字母或数字";
        errBox.hidden = false;
        return;
      }
      if (!(spots >= 1 && spots <= CFG.maxSpots)) {
        errBox.textContent = "剩余次数必须是 1–" + CFG.maxSpots + " 的整数";
        errBox.hidden = false;
        return;
      }
      const btn = $("#shareSubmit");
      btn.disabled = true;
      btn.textContent = "提交中…";
      try {
        await api.publish(code, spots);
        $("#codeInput").value = "";
        toast("分享成功：" + code + " 已排到队尾");
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

    $("#passportCopy").addEventListener("click", async () => {
      if (!state.head) return;
      const ok = await copyText(state.head.code);
      toast(ok ? "已复制：" + state.head.code : "复制失败，请手动选中", !ok);
    });

    $("#passportClaim").addEventListener("click", async () => {
      if (!state.head) return;
      await doClaim(state.head);
    });

    $("#passportFeedback").addEventListener("click", () => {
      if (!state.head) return;
      openFeedback(state.head);
    });

    $("#list").addEventListener("click", async (e) => {
      const btn = e.target.closest("button[data-act]");
      if (!btn) return;
      const card = state.cards.find((c) => String(c.id) === btn.dataset.id) ||
                   (state.head && String(state.head.id) === btn.dataset.id ? state.head : null);
      if (!card) return;
      if (btn.dataset.act === "copy") {
        const ok = await copyText(card.code);
        toast(ok ? "已复制：" + card.code : "复制失败，请手动选中", !ok);
      } else if (btn.dataset.act === "claim") {
        await doClaim(card);
      }
    });

    // 管理密钥
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
        localStorage.setItem(adminKeyStore, key);
        $("#adminPanel").hidden = false;
        toast("管理密钥已导入");
      } catch (e) {
        err.textContent = e.message;
        err.hidden = false;
      }
    });
    $("#adminClear").addEventListener("click", () => {
      localStorage.removeItem(adminKeyStore);
      $("#adminKeyInput").value = "";
      $("#adminPanel").hidden = true;
      toast("已清除本地密钥");
    });
    $("#adminApply").addEventListener("click", async () => {
      const key = localStorage.getItem(adminKeyStore) || $("#adminKeyInput").value.trim();
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
      } catch (e) {
        toast(e.message, true);
      }
    });
    $("#adminReseed").addEventListener("click", async () => {
      const key = localStorage.getItem(adminKeyStore) || $("#adminKeyInput").value.trim();
      try {
        await api.adminReseed(key);
        toast("顺位已重排为 1..N");
        await load();
      } catch (e) {
        toast(e.message, true);
      }
    });

    // 反馈
    $("#feedbackClose").addEventListener("click", () => ($("#feedbackModal").hidden = true));
    $("#feedbackCancel").addEventListener("click", () => ($("#feedbackModal").hidden = true));
    $("#feedbackModal").addEventListener("click", (e) => {
      if (e.target.id === "feedbackModal") $("#feedbackModal").hidden = true;
    });
    $("#feedbackSubmit").addEventListener("click", async () => {
      const target = state.feedbackTarget;
      if (!target) return;
      const err = $("#feedbackError");
      err.hidden = true;
      try {
        await api.feedback(target.id, $("#feedbackReason").value, $("#feedbackNote").value.trim());
        $("#feedbackModal").hidden = true;
        $("#feedbackNote").value = "";
        toast("反馈已提交，谢谢");
      } catch (e) {
        err.textContent = e.message;
        err.hidden = false;
      }
    });

    document.addEventListener("visibilitychange", () => {
      if (!document.hidden) load(true);
    });
    setInterval(() => {
      if (!document.hidden) load(true);
    }, 25000);
  }

  async function doClaim(card) {
    if (state.busy) return;
    state.busy = true;
    try {
      const res = await api.claim(card.id);
      const ok = await copyText(res.code);
      state.quota = res.quotaRemaining != null ? res.quotaRemaining : state.quota;
      toast("领到了 " + res.code + (ok ? "，已复制到剪贴板" : "，请手动复制"), false);
      await load(true);
    } catch (e) {
      toast(e.message, true);
    } finally {
      state.busy = false;
    }
  }

  function openFeedback(card) {
    state.feedbackTarget = card;
    $("#feedbackError").hidden = true;
    $("#feedbackModal").hidden = false;
  }

  function openAdmin() {
    const key = localStorage.getItem(adminKeyStore);
    $("#adminKeyInput").value = key || "";
    $("#adminPanel").hidden = !key;
    $("#adminError").hidden = true;
    $("#adminModal").hidden = false;
    if (key) {
      api.adminVerify(key).then(() => {
        $("#adminPanel").hidden = false;
      }).catch(() => {
        $("#adminPanel").hidden = true;
      });
    }
  }

  /* ------------------------------------------------------------ 启动 */

  fillSpots();
  wire();
  load();
  if (MODE === "demo") {
    $("#shareTip").textContent = "演示模式 · 仅本机可见";
  } else {
    $("#shareTip").textContent = "每人限 " + CFG.maxPublish + " 条";
  }
})();
