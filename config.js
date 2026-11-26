/* 站点配置
 *
 * 只填这两项就变成「全站共享」模式：
 *   supabaseUrl —— Supabase 项目地址，形如 https://xxxx.supabase.co
 *   supabaseKey —— 项目的 anon / publishable key（这两个都能放在前端，本来就是公开的）
 *
 * 两项都留空 → 站点自动进入「演示模式」，数据只存在浏览器的 localStorage 里，
 * 适合先看效果、或纯粹自用。
 *
 * 千万不要把 service_role / sb_secret_... 填进来。
 */
window.HUB_CONFIG = {
  supabaseUrl: "",
  supabaseKey: "",

  // 邀请码长度限制（小豆码一般 6 位，留宽一点更保险）
  codeMinLen: 4,
  codeMaxLen: 32,

  // 每个邀请码最多能被领走几次（1–30）
  maxSpots: 30,

  // 每人最多领几个码
  maxClaims: 2,

  // 每人最多同时保留几个自己的可用码
  maxPublish: 1,
};
