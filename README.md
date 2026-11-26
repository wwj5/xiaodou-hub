# 小豆邀请码互助站

社区互助用的邀请码共享站：谁手里有多余的小豆邀请码就放进来，需要的人自己领走。
队列按发布顺序排，队首优先展示，每被领走一次剩余次数 -1，减到 0 自动下架。

> 非官方项目，与小豆官方无隶属关系。

## 一、这版和 muse-invite-hub / BetterOPC 的关系

- 队列、通行证卡、分段筛选、复制/领取/反馈、管理密钥这套交互，参考 `WRM-FW/muse-invite-hub`。
- 「累计发放 / 当前可领取 / 揭晓后自动标记已领取」这套信息密度，参考 BetterOPC 的小豆邀请码页。
- 后端换了更轻的组合：**纯静态前端 + Supabase RPC**，不需要 Vite 构建、不需要 npm、不需要服务器进程，
  GitHub Pages 直接托管。整个仓库就是可部署产物。

## 二、功能

- 发布邀请码：前端口径校验（4–32 位字母或数字，统一大写并去掉非法字符）+ 数据库唯一索引兜底。
- 队列顺位：新码追加到队尾；管理员可把指定码插到任意顺位，其余码自动顺延。
- 领取：剩余次数 -1，领到 0 自动变「已用完」；同一访客同一个码只能领一次，每人最多领 2 个。
- 浏览：可用 / 已用完 / 全部三个筛选，支持按码搜索。
- 反馈：无效 / 已用掉 / 信息不对 / 其他四种原因，写进 Supabase 的 feedback 表，不自动改状态。
- 管理密钥：只存在管理员自己的浏览器 localStorage 里，可改剩余次数、顺位、状态，也可一键重排 1..N。
- 深浅色跟随系统；移动端无横向溢出。
- 没配置 Supabase 时自动进入**演示模式**（数据在 localStorage），可以先看效果。

## 三、部署到 GitHub Pages（三步）

1. 新建一个仓库，把这几个文件推上去：

   ```
   index.html  styles.css  app.js  config.js
   supabase/schema.sql  .github/workflows/pages.yml  README.md
   ```

2. 仓库 → Settings → Pages → Build and deployment → Source 选 **GitHub Actions**。
   推到 `main` 后 workflow 会自动发布，地址形如 `https://<你的用户名>.github.io/<仓库名>/`。

3. 前端默认不需要任何构建，页面里的路径全是相对路径，子目录部署也能直接用。

> 只想先看效果：这时候不填 Supabase，站点就是演示模式，能正常发布/领取，但只有你自己能看到。

## 四、接上 Supabase（让所有人共享同一份队列）

1. 到 supabase.com 建一个免费项目。
2. 打开 **SQL Editor**，把 `supabase/schema.sql` 全文粘贴执行一次。
3. 设置管理密钥（在同一个 SQL Editor 里执行，把里面的字符串换成你自己的一长串）：

   ```sql
   insert into public.app_settings (id, admin_token_hash)
   values (true, encode(sha256(convert_to('换成你自己的长密钥', 'UTF8')), 'hex'))
   on conflict (id) do update
     set admin_token_hash = excluded.admin_token_hash, updated_at = now();
   ```

4. 项目 → Settings → API，复制 **Project URL** 和 **anon public key**（不是 service_role），
   填进 `config.js`：

   ```js
   window.HUB_CONFIG = {
     supabaseUrl: "https://xxxx.supabase.co",
     supabaseKey: "eyJhbGciOi...",
     ...
   };
   ```

5. 提交推送到 GitHub，Pages 自动重建。打开站点，首页状态会变成「已连接」。

## 五、安全边界（说清楚，不吹牛）

- 数据库所有表都开了 RLS，`anon` 对表没有任何直连权限，只能通过 RPC 函数读写。
- 所有写函数都是 `SECURITY DEFINER` + 固定 `search_path`，只 `grant execute` 给 `anon`。
- 发布、领取、反馈都有服务端限流：1 个可用码/人、2 次领取/人、60 次操作/小时、
  10 条反馈/天、全站 30 条发布/10 分钟。
- 限流基于浏览器 visitor token，清空 localStorage 可以绕过——这点和 muse 一样，是匿名架构的固有取舍。
- 邀请码本身是公开的，挡不住别人抢先兑换；互助站就是这个特性。
- Supabase Security Advisor 仍会把「anon 可执行 SECURITY DEFINER」标成警告，这是匿名 RPC 架构的必然提示。
- 管理密钥是高权限凭据，只该放在你自己的设备上，别写进仓库、别发群里。

## 六、本地预览

不用装任何东西，把目录用任意静态服务器带起来即可：

```bash
python -m http.server 8787
# 然后打开 http://127.0.0.1:8787
```

直接双击 `index.html` 也能看，但浏览器会限制 `file://` 下的部分行为，建议用上面的方式。

## 七、表结构速览

| 表 | 作用 |
|---|---|
| `invite_codes` | 邀请码主表：码、状态、剩余次数、已领次数、队列顺位、发布者哈希 |
| `reports` | 领取/使用记录，用来做去重和「每人最多领 2 个」计数 |
| `publish_log` | 发布流水，用来做全站发布限流 |
| `feedback` | 反馈收件箱：原因、说明、是否处理 |
| `app_settings` | 只存一行通用管理密钥的 SHA-256 |
