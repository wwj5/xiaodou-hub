# 小豆邀请码互助站（揭晓制）

社区互助用的邀请码共享站，核心是**不把邀请码挂在明面上**：列表里只有遮罩和状态，
点「揭晓」才返回明文，揭晓那一刻就标记为已领取、扣减剩余次数、消耗你自己的每日名额。
这样爬虫扫页面也扫不到码，不会出现"刚放上去就被脚本秒掉"的情况。

> 非官方项目，与小豆官方无隶属关系。

## 一、跟 muse-invite-hub / BetterOPC 的关系

- 队列、票券式队首卡、分段筛选、反馈、管理密钥这一套交互，参考 `WRM-FW/muse-invite-hub`<sup>①</sup>。
- 「列表不给明文，点揭晓才出码」「揭晓即标记已领取」「今日揭晓次数用完就停」「北京时间 0 点重置」
  这一套信息与交互，参考 BetterOPC 的小豆邀请码页。
- 实现上换了更轻的组合：纯静态前端 + Supabase RPC，不需要 Vite、npm、服务器进程，
  GitHub Pages 直接托管，仓库本身就是部署产物。

## 二、功能

- **揭晓制**：`list_codes` 只返回 `mask`（``••••••``）与状态，明文只从 `reveal_code` 出来。
- **揭晓即领取**：剩余次数 -1，领到 0 自动变「已揭晓」；同一个码同一个访客只能揭一次。
- **每日配额**：每人每天 2 次揭晓，按北京时间 0 点重置；用完按钮直接禁用并提示。
- 发布：4–32 位字母或数字、统一大写去非法字符，数据库唯一索引兜底；同一个人最多保留 1 个可用码。
- 队列顺位：新码追加队尾；管理员可插到任意位置，其余码自动顺延，也能一键重排 1..N。
- 筛选（可揭晓 / 已揭晓 / 全部）与搜索（搜到也只是"池里有这个码"，不返回明文）。
- 反馈：无效 / 已用掉 / 信息不对 / 其他，写进 Supabase `feedback` 表，不自动改状态。
- 管理密钥：只存在管理员自己浏览器里，可改剩余次数、顺位、状态；管理端能看到明文。
- 本机记录：你揭晓到的码存在本地浏览器，刷新后还能看到，也可以再复制。
- 深浅色跟随系统，移动端无横向溢出；没配 Supabase 时是演示模式。

## 三、部署到 GitHub Pages

1. 新建仓库，把这几个文件推上去：

   ```
   index.html  styles.css  app.js  config.js
   supabase/schema.sql  .github/workflows/pages.yml  README.md
   ```

2. Settings → Pages → Build and deployment → Source 选 **GitHub Actions**。
   推到 `main` 后自动发布，地址形如 `https://<用户名>.github.io/<仓库名>/`。

3. 不用任何构建步骤，页面全是相对路径，子目录部署也能直接开。

## 四、接上 Supabase（全站共享 + 真揭晓）

1. 建一个 Supabase 免费项目。
2. SQL Editor 里把 `supabase/schema.sql` 整段执行一次。
3. 设管理密钥（同一编辑器里执行，换成你自己的长字符串）：

   ```sql
   insert into public.app_settings (id, admin_token_hash)
   values (true, encode(sha256(convert_to('换成你自己的长密钥', 'UTF8')), 'hex'))
   on conflict (id) do update
     set admin_token_hash = excluded.admin_token_hash, updated_at = now();
   ```

4. Settings → API 里复制 **Project URL** 和 **anon public key**（不要 service_role），填进 `config.js`：

   ```js
   window.HUB_CONFIG = {
     supabaseUrl: "https://xxxx.supabase.co",
     supabaseKey: "eyJhbGciOi...",
     dailyReveals: 2,
     ...
   };
   ```

5. 推上去，Pages 自动重建。首页状态会变成「已连接」。

> 只填空配置时站点是**演示模式**：发布/揭晓都能用，但数据只在这台浏览器里。

## 五、为什么这样不容易被秒

| 手段 | 作用 |
|---|---|
| 列表零明文 | 任何人抓 `list_codes` 拿到的只有 `••••••`，脚本没有可抢的东西 |
| 揭晓才出码 | 明文只在 `reveal_code` 一次性返回给揭晓人 |
| 揭晓即扣减 | 别人揭走后码就被标记，后来者看到「已被揭」 |
| 每日配额 | 同一个 visitor 每天 2 次，抓不到批量结果 |
| 服务端限流 | 发布 1 条/人、全站 30 条/10 分钟；揭晓 30 次/小时 |
| RLS + RPC | `anon` 对表零权限，只能通过函数做受限操作 |

## 六、诚实的限制

- 限流按浏览器 visitor token 算，清空 localStorage 能绕开——这点和 muse 一样，是匿名架构的取舍。
  要更强的身份约束就得上 Supabase Auth（邮箱 OTP）或 Cloudflare Turnstile，前端改动不大。
- 邀请码本身仍可能被别人抢先兑换；揭晓制只是把"谁先看到"拉平，不能保证兑换一定成功。
- 搜索接口能验证"池里有没有这个码"，但拿不到明文，是个很弱的信息泄漏。
- 管理密钥是高权限凭据，只应放在管理员自己的设备上，别进仓库、别发群。
- Supabase Security Advisor 仍会把「anon 可执行 SECURITY DEFINER」标成警告，这是匿名 RPC 架构必然提示。

## 七、本地预览

```bash
python -m http.server 8787
# 打开 http://127.0.0.1:8787
```

## 八、表结构速览

| 表 | 作用 |
|---|---|
| `invite_codes` | 主表：明文码、状态、剩余次数、已揭次数、队列顺位、发布者哈希 |
| `reports` | 揭晓记录：去重 + 每日配额 + 「每人每天 2 次」计数 |
| `publish_log` | 发布流水，用于全站限流 |
| `feedback` | 反馈收件箱 |
| `app_settings` | 单行通用管理密钥的 SHA-256 |

## 九、已验证

- 本地浏览器实测：遮罩展示、揭晓出码并自动复制、配额 2→1→0、按钮变「今日名额已用完」、本机记录同步。
- 嵌入式 PostgreSQL 实跑 `schema.sql`：列表返回不含 `code` 键、`reveal_code` 返回明文并扣减次数、
  第三次揭晓被每日配额拦住、同码重复揭晓被拦、`anon` 只能拿到遮罩、管理端可见明文。
