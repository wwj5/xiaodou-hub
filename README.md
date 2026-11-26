# 小豆邀请码互助站（揭晓制）

<img alt="小豆邀请码互助站" src="assets/share-cover-wide.jpg" width="600">

<p>
  <a href="https://github.com/wwj5/xiaodou-hub/actions/workflows/pages.yml"><img alt="部署" src="https://github.com/wwj5/xiaodou-hub/actions/workflows/pages.yml/badge.svg"></a>
  <a href="https://wwj5.github.io/xiaodou-hub/"><img alt="站点" src="https://img.shields.io/badge/site-wwj5.github.io%2Fxiaodou--hub-2ea44f"></a>
  <a href="LICENSE"><img alt="许可" src="https://img.shields.io/badge/license-MIT-3da639"></a>
  <img alt="后端" src="https://img.shields.io/badge/backend-Supabase-3ecf8e?logo=supabase&logoColor=white">
  <img alt="前端" src="https://img.shields.io/badge/frontend-pure%20static%20%2B%20no%20build-1f6feb">
  <a href="https://github.com/wwj5/xiaodou-hub"><img alt="Stars" src="https://img.shields.io/github/stars/wwj5/xiaodou-hub?style=flat&logo=github&label=stars"></a>
</p>

**站点：https://wwj5.github.io/xiaodou-hub/**

社区互助用的邀请码共享站，核心是**不把邀请码挂在明面上**：列表里只有遮罩和状态，
点「揭晓」才返回明文，揭晓那一刻就标记为已领取、扣减剩余次数、消耗你自己的每日名额。
这样爬虫扫页面也扫不到码，不会出现"刚放上去就被脚本秒掉"的情况。

> 非官方项目，与小豆官方无隶属关系。

## 一、跟 muse-invite-hub / BetterOPC 的关系

- 队列、队首优先、反馈、管理密钥这一套交互，参考 `WRM-FW/muse-invite-hub`<sup>①</sup>。
- 页面结构照 BetterOPC 的小豆邀请码页：蓝色渐变产品头卡（含「邀请双方各得 1200 额度积分」块）、
  「累计发放 / 当前可揭晓」统计块、卡片网格、空态提示、领取记录；今日揭晓额度不在页面上显示，用完直接拦在接口层。
- 「列表不给明文，点揭晓才出码」「揭晓即标记已领取」「今日揭晓次数用完就停」「北京时间 0 点重置」
  这一套信息与交互，同样来自那一页。
- 实现上换了更轻的组合：纯静态前端 + Supabase RPC，不需要 Vite、npm、服务器进程，
  GitHub Pages 直接托管，仓库本身就是部署产物。

## 二、功能

- **免费纯接力**：不收钱、不卖码。揭晓成功会弹一次「拿到了，接力一下」，提示把自己的码放回池子；
  接过几个码就在首页挂一条「接力中」提示，真去分享了就清零。
- **揭晓制**：`list_codes` 只返回 `mask`（``••••••``）与状态，明文只从 `reveal_code` 出来。
- **揭晓即领取**：剩余次数 -1，领到 0 自动变「已揭晓」；同一个码同一个访客只能揭一次。
- **每日配额**：每人每天 2 次揭晓，按北京时间 0 点重置；用完按钮直接禁用并提示。
- 发布：点「＋ 分享邀请码」弹窗提交，字段接受**邀请码本身或官方邀请链接**——链接里的
  `invite_code/inviteCode/code`、或路径里的码段会自动解析出来；也认「邀请码：XXXX」这种文本。
  4–32 位字母或数字、统一大写去非法字符，数据库唯一索引兜底；同一个人最多保留 1 个可用码。
- 队列顺位：新码追加队尾；管理员可插到任意位置，其余码自动顺延，也能一键重排 1..N。
- 列表只展示可揭晓的码（按顺位），已揭完的沉到「领取记录」，页面不做搜索框——少一个能探消息的口子。
- 反馈：无效 / 已用掉 / 信息不对 / 其他，写进 Supabase `feedback` 表，不自动改状态。
- 管理密钥：只存在管理员自己浏览器里，可改剩余次数、顺位、状态；管理端能看到明文。
- 本机记录：你揭晓到的码存在本地浏览器，刷新后还能看到，也可以再复制。
- 开场公告：首页打开先弹一次「接力说明（公告）」，讲清码只送不卖、拿了要放回来；
  可勾「今天不再显示」，按北京时间当天生效，次日自动恢复。
- 玩法说明收进弹窗：页面只留一句原理和「看完整说明」按钮，7 个步骤（先拿 3 步 / 再放回 4 步）
  两栏排在弹窗里，底部是免责与接力规则；首屏链接、页脚「使用说明 / 免责声明」都是同一个入口。
- 空池文案：池子空了不是「没开放」，而是提示接力断了，引导「先放一个进来」或直接看说明。
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

- 身份是「浏览器指纹」哈希：清 localStorage 不会变成新访客，但换浏览器/换设备仍然是新身份（匿名架构的上限）。
  同型号同系统设备存在指纹碰撞的可能，届时两个人会共用一份额度，属于宁可误伤不漏放的选择。
- 接力硬规则：第一个码免费接，之后每接 1 个必须放回 1 个**仍在池中未被下架**的码；发废码占位被发现后解锁自动失效。
- 同一个码被 2 个不同访客举报，会自动置为 `expired` 摘出池子，等管理员在后台核验；不用人工盯。
  要更强的身份约束就得上 Supabase Auth（邮箱 OTP）或 Cloudflare Turnstile，前端改动不大。
- 邀请码本身仍可能被别人抢先兑换；揭晓制只是把"谁先看到"拉平，不能保证兑换一定成功。
- `list_codes` 的 `p_query` 参数还在（能验证"池里有没有这个码"，拿不到明文），但页面已经没有搜索框；
  真要彻底关掉，把它固定传空字符串或在函数里删掉这段过滤即可。
- 管理密码是高权限凭据，只应放在管理员自己的设备上，别进仓库、别发群。
- Supabase Security Advisor 仍会把「anon 可执行 SECURITY DEFINER」标成警告，这是匿名 RPC 架构必然提示。

## 七、当前线上实例

| 项 | 值 |
|---|---|
| 站点 | https://wwj5.github.io/xiaodou-hub/ |
| 仓库 | https://github.com/wwj5/xiaodou-hub （public） |
| Supabase 项目 | `cusioozwyyrdghgvaaqw` · 组织 `xiaodou` · 区域 Southeast Asia (Singapore) · FREE |
| 后端 URL | https://cusioozwyyrdghgvaaqw.supabase.co |
| 前端配置 | `config.js` 里 `supabaseUrl` + anon key（anon key 是公开可暴露的，RLS 兜底） |
| 管理密码 | 只写在本地 `.supabase-keys.txt` 的 `admin_key` 一行（已 gitignore，不进仓库） |
| 数据库密码 | 只写在本地 `.supabase-db-password.txt`（已 gitignore）；丢了可在 Dashboard → Settings → Database 重置 |

改代码后 `git push origin main`，GitHub Actions 自动重跑并发布，约 30 秒上线。

## 八、管理后台

独立页面 `/admin.html`（首页页脚「管理入口」进入，`noindex`，只靠密码把门）：

- 输入管理密码 → `admin_verify` 校验，密码只存 sessionStorage，关浏览器即失效；
- 四张统计卡：累计发放 / 当前可揭 / 今日揭晓 / 待处理举报；
- 全量码表（明文、状态、剩余/总、顺位、已揭、发布时间），每行可「下架 / 恢复 / 置顶 / 删除」；
- 待处理举报列表，可「标记已处理」，或「下架该码并处理」一键联动；
- 右上「改密码」调 `admin_set_key`（新密码 ≥ 8 位），改完立刻生效；
- **接力账本**（`admin_ledger`）：按设备指纹列出「揭晓几个 / 回填几个 / 欠几个 / 最后活跃 / 状态」，
  欠码的排最前，可勾「只看欠码的」，一键导出 CSV；
- **设备限制**（`admin_block` / `admin_unblock`）：按住欠码不放的设备，限制后它再点「揭晓」会被
  `reveal_code` 直接拒绝（提示先把欠的码还回来），随时可解除。

> 账本只认前端算出的匿名设备指纹（`sha256('xd-hub:' + token)`），**不采集 IP、不采集姓名或手机号**，
> 后台也看不到任何可反查真人的信息；页面公开处只给聚合数字（「有 N 人拿了码还没放回来」），不点名。

对应 RPC：`admin_list`、`admin_delete_code`、`admin_resolve_report`、`admin_set_key`、`admin_ledger`、
`admin_block`、`admin_unblock`（都先过 `hub_require_admin`，anon 可调但没密码就是「管理密码不对」）。

## 九、本地预览

```bash
python -m http.server 8787
# 打开 http://127.0.0.1:8787
```

## 十、表结构速览

| 表 | 作用 |
|---|---|
| `invite_codes` | 主表：明文码、状态、剩余次数、已揭次数、队列顺位、发布者哈希 |
| `reports` | 揭晓记录：去重 + 每日配额 + 「每人每天 2 次」计数 |
| `publish_log` | 发布流水，用于全站限流 |
| `feedback` | 反馈收件箱 |
| `app_settings` | 单行管理密码的 SHA-256（页面右上「改密码」可换） |

## 十一、已验证

- 线上 Supabase 实测（anon key 直调 RPC）：`list_codes` 只给 `mask`、`publish_code` 成功入队、
  `reveal_code` 出码并让 `revealedCount` 从 0 → 1。
- 嵌入式 PostgreSQL 实跑 `schema.sql`：列表返回不含 `code` 键、`reveal_code` 返回明文并扣减次数、
  第三次揭晓被每日配额拦住、同码重复揭晓被拦、`anon` 只能拿到遮罩、管理端可见明文。
- 接力硬规则实测：第一个码免费接 → 接第二个被拦（未放回）→ 发布自己的码后解锁。
- 公告/说明弹窗实测：勾「今天不再显示」后当天不再弹（`localStorage` 记北京时间日期）；
  「去回填邀请码」直接打开提交框并聚焦；公告里的「看 4 步说明」关公告、直接弹说明。

## 十二、许可

MIT，见 [LICENSE](LICENSE)。代码可以拿去改，改成你自己社群用的站也随意；但要保留版权声明，
并且别把「小豆」「豆包」这些名字和 logo 拿来暗示官方授权。



