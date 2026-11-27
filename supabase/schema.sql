-- 小豆邀请码互助站 · Supabase 数据库初始化（揭晓制版本）
-- 在 Supabase Dashboard → SQL Editor 里整段粘贴执行一次即可。
--
-- 核心策略：邀请码在列表接口里永远不出现明文，只有「揭晓」这个动作才返回，
-- 并且揭晓即标记为已领取、扣减剩余次数、计入每人每日揭晓配额。
-- 前端只拿 anon key；所有写操作走 SECURITY DEFINER RPC；只依赖内置 sha256()。

-- ---------------------------------------------------------------- 表

create table if not exists public.invite_codes (
  id              uuid primary key default gen_random_uuid(),
  code            text not null,
  code_norm       text not null,
  status          text not null default 'available'
                  check (status in ('available', 'used', 'expired')),
  total_spots     integer not null default 1 check (total_spots between 1 and 30),
  remaining_spots integer not null default 1 check (remaining_spots between 0 and 30),
  claimed_count   integer not null default 0,
  queue_rank      integer not null,
  creator_hash    text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create unique index if not exists ux_invite_codes_norm on public.invite_codes (code_norm);
create index if not exists ix_invite_codes_status on public.invite_codes (status, queue_rank);

create table if not exists public.reports (
  id           bigserial primary key,
  code_id      uuid references public.invite_codes (id) on delete set null,
  action       text not null check (action in ('reveal')),
  visitor_hash text not null,
  created_at   timestamptz not null default now()
);

create unique index if not exists ux_reports
  on public.reports (code_id, visitor_hash, action);
create index if not exists ix_reports_visitor
  on public.reports (visitor_hash, action, created_at);

create table if not exists public.publish_log (
  id           bigserial primary key,
  visitor_hash text not null,
  code_id      uuid,
  created_at   timestamptz not null default now()
);
create index if not exists ix_publish_log_time on public.publish_log (created_at);

create table if not exists public.feedback (
  id           bigserial primary key,
  code_id      uuid references public.invite_codes (id) on delete set null,
  code         text,
  reason       text not null check (reason in ('invalid', 'used', 'wrong_info', 'other')),
  note         text,
  visitor_hash text,
  resolved     boolean not null default false,
  created_at   timestamptz not null default now()
);
create index if not exists ix_feedback_time on public.feedback (visitor_hash, created_at);

create table if not exists public.app_settings (
  id               boolean primary key default true check (id),
  admin_token_hash text not null,
  -- 超时未回填自动限制：拿到码多少分钟内没放回自己的码，就自动限制这台设备（0 = 关闭）
  autoblock_minutes integer not null default 5 check (autoblock_minutes between 0 and 1440),
  updated_at       timestamptz not null default now()
);

-- 兼容老库：补上超时限制字段
alter table public.app_settings
  add column if not exists autoblock_minutes integer not null default 5;

-- 页面水印：后台可改字、可调深浅；前端用 canvas 现场画，不用重新部署
alter table public.app_settings
  add column if not exists wm_line1 text not null default '自觉回填邀请码';
alter table public.app_settings
  add column if not exists wm_line2 text not null default '拿码不回 · 限制设备';
alter table public.app_settings
  add column if not exists wm_opacity numeric not null default 0.11;

-- 出码方式：auto = 点一下就自动揭晓；manual = 填申请，站长人工把码发过去（防跑路）
alter table public.app_settings
  add column if not exists reveal_mode text not null default 'manual';
do $$ begin
  alter table public.app_settings add constraint ck_reveal_mode check (reveal_mode in ('auto', 'manual'));
exception when duplicate_object then null; end $$;

-- 发码申请：想拿码的人先留联系方式，站长核对欠账后手动发
create table if not exists public.reveal_requests (
  id           bigserial primary key,
  visitor_hash text not null,
  contact      text not null,
  note         text,
  status       text not null default 'open' check (status in ('open', 'sent', 'rejected')),
  code_id      uuid,
  handled_at   timestamptz,
  created_at   timestamptz not null default now()
);
create index if not exists ix_reveal_requests_status on public.reveal_requests (status, created_at);

-- 拉黑名单：只按设备指纹，不记 IP、不记个人身份信息
-- kind: manual = 管理员手动限制；auto = 超时未回填自动限制（回填后会自动解除）
create table if not exists public.visitor_blocks (
  visitor_hash text primary key,
  note         text,
  kind         text not null default 'manual',
  created_at   timestamptz not null default now()
);
alter table public.visitor_blocks
  add column if not exists kind text not null default 'manual';

-- 被拒收的提交（只给后台看，用来判断规则是不是误杀了真码）
create table if not exists public.reject_log (
  id           bigserial primary key,
  code_norm    text not null,
  visitor_hash text,
  reason       text not null,
  created_at   timestamptz not null default now()
);
create index if not exists ix_reject_log_time on public.reject_log (created_at desc);

-- 设备档案：只记"这台设备来过、大概在哪、什么浏览器"，用来做欠码公示
-- ip_full 只给后台解析城市用（不入任何公开接口）；对外只出 ip_masked（61.178.*.*）
create table if not exists public.visitor_meta (
  visitor_hash text primary key,
  ip_full      inet,
  ip_masked    text,
  city         text,
  city_at      timestamptz,
  ua_short     text,
  first_seen   timestamptz not null default now(),
  last_seen    timestamptz not null default now(),
  hits         integer not null default 0
);
create index if not exists ix_visitor_meta_seen on public.visitor_meta (last_seen desc);

alter table public.visitor_meta enable row level security;
revoke all on public.visitor_meta from anon, authenticated;

-- IP 脱敏：v4 留前两段，v6 留前三组
create or replace function public.hub_mask_ip(p_ip text)
returns text
language plpgsql
immutable
as $$
declare
  v_addr inet;
  v_host text;
begin
  if p_ip is null or btrim(p_ip) = '' then
    return '';
  end if;
  begin
    v_addr := btrim(p_ip)::inet;
  exception when others then
    return '';
  end;
  v_host := host(v_addr);
  if family(v_addr) = 4 then
    return split_part(v_host, '.', 1) || '.' || split_part(v_host, '.', 2) || '.*.*';
  end if;
  return array_to_string((string_to_array(v_host, ':'))[1:3], ':') || ':****';
end;
$$;

-- 浏览器 / 设备短标签：先认容器（微信、QQ），再认设备和内核
create or replace function public.hub_ua_short(p_ua text)
returns text
language sql
immutable
as $$
  select case
    when p_ua is null or btrim(p_ua) = '' then ''
    else
      (case
        when p_ua ilike '%micromessenger%' then '微信'
        when p_ua ilike '%qq/%' or p_ua ilike '%qqbrowser%' then 'QQ'
        when p_ua ilike '%edga%' or p_ua ilike '%edg/%' then 'Edge'
        when p_ua ilike '%firefox%' then 'Firefox'
        when p_ua ilike '%crios%' or p_ua ilike '%chrome%' then 'Chrome'
        when p_ua ilike '%safari%' then 'Safari'
        else '浏览器'
      end)
      || ' · ' ||
      (case
        when p_ua ilike '%iphone%' then 'iPhone'
        when p_ua ilike '%ipad%' then 'iPad'
        when p_ua ilike '%android%' then '安卓'
        when p_ua ilike '%windows%' then 'Windows'
        when p_ua ilike '%macintosh%' then 'Mac'
        when p_ua ilike '%linux%' then 'Linux'
        else '未知设备'
      end)
    end
  end;
$$;

-- 每次有设备动一下就记一笔（取 Supabase 网关透传的 x-forwarded-for）
-- 旧的一参数签名先清掉，避免和新版并存造成调用歧义
drop function if exists public.hub_touch(text);
create or replace function public.hub_touch(p_visitor text, p_throttle_minutes integer default 0)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_hdrs jsonb;
  v_ip   text;
  v_ua   text;
  v_addr inet;
begin
  if p_visitor is null or length(p_visitor) < 8 then
    return;
  end if;

  -- 节流：只是刷新首页这种，别每次都写库
  if coalesce(p_throttle_minutes, 0) > 0 and exists (
    select 1 from public.visitor_meta m
     where m.visitor_hash = p_visitor
       and m.last_seen > now() - make_interval(mins => p_throttle_minutes)
  ) then
    return;
  end if;

  begin
    v_hdrs := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  exception when others then
    v_hdrs := '{}'::jsonb;
  end;

  v_ip := btrim(split_part(coalesce(v_hdrs ->> 'x-forwarded-for', v_hdrs ->> 'x-real-ip', ''), ',', 1));
  v_ua := left(coalesce(v_hdrs ->> 'user-agent', ''), 400);

  begin
    v_addr := nullif(v_ip, '')::inet;
  exception when others then
    v_addr := null;
  end;

  insert into public.visitor_meta as m
    (visitor_hash, ip_full, ip_masked, ua_short, first_seen, last_seen, hits)
  values
    (p_visitor, v_addr, public.hub_mask_ip(v_ip), public.hub_ua_short(v_ua), now(), now(), 1)
  on conflict (visitor_hash) do update
    set ip_full   = coalesce(excluded.ip_full, m.ip_full),
        ip_masked = coalesce(nullif(excluded.ip_masked, ''), m.ip_masked),
        ua_short  = coalesce(nullif(excluded.ua_short, ''), m.ua_short),
        last_seen = now(),
        hits      = m.hits + 1;
end;
$$;

-- 在线客服：一台设备一个会话，访客只填正文，不要求注册
create table if not exists public.chat_threads (
  id             bigserial primary key,
  visitor_hash   text not null unique,
  nickname       text,
  city           text,
  status         text not null default 'open',
  unread_admin   integer not null default 0,
  unread_visitor integer not null default 0,
  last_at        timestamptz not null default now(),
  created_at     timestamptz not null default now()
);
create index if not exists ix_chat_threads_last on public.chat_threads (last_at desc);

create table if not exists public.chat_messages (
  id         bigserial primary key,
  thread_id  bigint not null references public.chat_threads(id) on delete cascade,
  side       text not null,
  body       text not null,
  created_at timestamptz not null default now()
);
create index if not exists ix_chat_msg_thread on public.chat_messages (thread_id, id);

alter table public.chat_threads  enable row level security;
alter table public.chat_messages enable row level security;
revoke all on public.chat_threads  from anon, authenticated;
revoke all on public.chat_messages from anon, authenticated;

-- ---------------------------------------------------------------- 权限：表一律不可直连

alter table public.invite_codes  enable row level security;
alter table public.reports       enable row level security;
alter table public.publish_log   enable row level security;
alter table public.feedback      enable row level security;
alter table public.app_settings  enable row level security;
alter table public.visitor_blocks enable row level security;
alter table public.reject_log    enable row level security;
alter table public.reveal_requests enable row level security;

revoke all on public.invite_codes  from anon, authenticated;
revoke all on public.reports       from anon, authenticated;
revoke all on public.publish_log   from anon, authenticated;
revoke all on public.feedback      from anon, authenticated;
revoke all on public.app_settings  from anon, authenticated;
revoke all on public.visitor_blocks from anon, authenticated;
revoke all on public.reject_log    from anon, authenticated;
revoke all on public.reveal_requests from anon, authenticated;

-- ---------------------------------------------------------------- 内部小工具

create or replace function public.hub_hash(p_token text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select encode(sha256(convert_to('xd-hub:' || coalesce(p_token, ''), 'UTF8')), 'hex');
$$;

create or replace function public.hub_today()
returns date
language sql
stable
set search_path = public, pg_temp
as $$
  select ((now() at time zone 'UTC') + interval '8 hours')::date;
$$;

-- 收录规则集中在一处：返回不收的理由，合格返回 null。
-- 发布时用它拦，后台「清理不合规」也用它判定，两边口径不会跑偏。
create or replace function public.hub_code_problem(p_code text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  with c as (select upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')) as n)
  select case
    when n is null or n = ''           then '邀请码是空的'
    when length(n) <> 6                then '邀请码必须是 6 位，这个是 ' || length(n) || ' 位'
    when n !~ '[A-Z]' or n !~ '[0-9]'  then '邀请码必须字母和数字都有'
    when n ~ '[A-Z]{3}'                then '邀请码里有 3 个字母连在一起'
    when n ~ '[0-9]{3}'                then '邀请码里有 3 个数字连在一起'
    when n = any (array['OPENAI','CLOUD','GOOGLE','GITHUB','DOUBAO','PYTHON','MOBILE','SERVER','WINDOW','SYSTEM','PUBLIC','MASTER','SECRET'])
                                       then '这看着是英文单词'
    when n ~ '(91|78|13|27)'           then '邀请码里带了 91 / 78 / 13 / 27'
    else null
  end
  from c;
$$;

-- 超时未回填的宽限分钟数（0 = 关闭自动限制）
create or replace function public.hub_grace_minutes()
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((select autoblock_minutes from public.app_settings where id = true), 5);
$$;

-- 当前出码方式：auto = 点一下自动揭晓；manual = 填申请、站长人工发码（默认，防跑路）
create or replace function public.hub_reveal_mode()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((select reveal_mode from public.app_settings where id = true), 'manual');
$$;

-- 超时未回填 → 自动把该设备指纹写进限制名单；回填后由 publish_code 自动解除
-- 判定口径：拿到的码数 > 已放回数，且"第一笔没被回填抵消的那次揭晓"已经超过宽限时间
create or replace function public.hub_autoblock(p_visitor text)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_min   integer := public.hub_grace_minutes();
  v_taken integer;
  v_ret   integer;
  v_old   timestamptz;
begin
  if v_min is null or v_min <= 0 then
    return false;
  end if;
  if exists (select 1 from public.visitor_blocks where visitor_hash = p_visitor) then
    return true;
  end if;

  select count(*) into v_taken
    from public.reports r
    join public.invite_codes c on c.id = r.code_id
   where r.visitor_hash = p_visitor and r.action = 'reveal' and c.status <> 'expired';
  select count(*) into v_ret
    from public.invite_codes
   where creator_hash = p_visitor and status <> 'expired';

  if v_taken <= v_ret then
    return false;
  end if;

  -- 已回填 k 个，就抵掉最早的 k 次揭晓；第 k+1 次揭晓的时间才是真正的截止起点
  select t.created_at into v_old
    from (
      select r.created_at, row_number() over (order by r.created_at) as rn
        from public.reports r
        join public.invite_codes c on c.id = r.code_id
       where r.visitor_hash = p_visitor and r.action = 'reveal' and c.status <> 'expired'
    ) t
   where t.rn = v_ret + 1;

  if v_old is not null and v_old < now() - make_interval(mins => v_min) then
    insert into public.visitor_blocks (visitor_hash, note, kind)
    values (p_visitor, '超时 ' || v_min || ' 分钟未回填，自动限制', 'auto')
    on conflict (visitor_hash) do nothing;
    return true;
  end if;

  return false;
end;
$$;

create or replace function public.hub_stats()
returns json
language sql
security definer
set search_path = public, pg_temp
as $$
  select json_build_object(
    'issued',         (select count(*) from public.invite_codes),
    'available',      (select count(*) from public.invite_codes where status = 'available'),
    'revealed',       (select count(*) from public.invite_codes where status <> 'available'),
    'revealedCount',  (select coalesce(sum(claimed_count), 0) from public.invite_codes),
    'availableSpots', (select coalesce(sum(remaining_spots), 0) from public.invite_codes where status = 'available'),
    -- 公开只用聚合数：拿了码还没还回填的人数，不点名、不带任何可定位信息
    'unreturned',     (
      select count(*)
        from (
          select r.visitor_hash as vh, count(*) as n
            from public.reports r
            join public.invite_codes c on c.id = r.code_id
           where r.action = 'reveal' and c.status <> 'expired'
           group by 1
        ) a
        left join (
          select creator_hash as vh, count(*) as n
            from public.invite_codes
           where creator_hash is not null and status <> 'expired'
           group by 1
        ) b on b.vh = a.vh
       where a.n > coalesce(b.n, 0)
    ),
    -- 超时未回填的宽限分钟（前端用来提示"多久内必须放回"）
    'graceMinutes',   public.hub_grace_minutes(),
    -- 出码方式：auto 自动揭晓 / manual 申请后人工发码
    'revealMode',     public.hub_reveal_mode(),
    -- 页面水印（后台可改，前端现场画）
    'wm', json_build_object(
      'line1',   coalesce((select wm_line1   from public.app_settings where id = true), '自觉回填邀请码'),
      'line2',   coalesce((select wm_line2   from public.app_settings where id = true), '拿码不回 · 限制设备'),
      'opacity', coalesce((select wm_opacity from public.app_settings where id = true), 0.11)
    )
  );
$$;

-- 对外卡片：不带明文邀请码，只给遮罩长度和状态
create or replace function public.hub_card_public(p_row public.invite_codes)
returns json
language sql
stable
set search_path = public, pg_temp
as $$
  select json_build_object(
    'id',             p_row.id,
    'mask',           repeat('•', greatest(length(p_row.code), 4)),
    'status',         p_row.status,
    'totalSpots',     p_row.total_spots,
    'remainingSpots', p_row.remaining_spots,
    'claimedCount',   p_row.claimed_count,
    'queueRank',      p_row.queue_rank,
    'createdAt',      p_row.created_at,
    -- 已经被揭走的码（remaining 0 / 已下架）在「领取记录」里直接给明文：
    -- 这些码已经交到一个接码人手里，标「可能已被使用」提醒后来者别惦记
    'codePlain',      case when p_row.status <> 'available' then p_row.code else null end,
    -- 15 分钟内放进来的算「实时新码」，前端置顶并打标
    'fresh',          p_row.created_at >= now() - interval '15 minutes'
  );
$$;

-- 只有揭晓之后（或管理员）才用这张卡，带明文
create or replace function public.hub_card_full(p_row public.invite_codes)
returns json
language sql
immutable
set search_path = public, pg_temp
as $$
  select json_build_object(
    'id',             p_row.id,
    'code',           p_row.code,
    'status',         p_row.status,
    'totalSpots',     p_row.total_spots,
    'remainingSpots', p_row.remaining_spots,
    'claimedCount',   p_row.claimed_count,
    'queueRank',      p_row.queue_rank,
    'createdAt',      p_row.created_at,
    -- 后台用：这枚码符不符合现在的收录规则
    'bad',            public.hub_code_problem(p_row.code) is not null
  );
$$;

create or replace function public.hub_require_admin(p_key text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_hash text;
begin
  if p_key is null or length(trim(p_key)) = 0 then
    raise exception '需要管理密码' using errcode = 'P0001';
  end if;
  select admin_token_hash into v_hash from public.app_settings where id = true;
  if v_hash is null or v_hash <> encode(sha256(convert_to(trim(p_key), 'UTF8')), 'hex') then
    raise exception '管理密码不对' using errcode = 'P0001';
  end if;
end;
$$;

-- 通用管理密码由你自己执行一次（把字符串换掉）：
-- insert into public.app_settings (id, admin_token_hash)
-- values (true, encode(sha256(convert_to('你设置的一长串密码', 'UTF8')), 'hex'))
-- on conflict (id) do update
--   set admin_token_hash = excluded.admin_token_hash, updated_at = now();

-- ---------------------------------------------------------------- RPC：读（不含明文）

create or replace function public.list_codes(
  p_status text default 'available',
  p_query  text default '',
  p_limit  integer default 500,
  p_offset integer default 0,
  p_token  text default ''
)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status text := coalesce(nullif(trim(p_status), ''), 'available');
  v_query  text := upper(regexp_replace(coalesce(p_query, ''), '[^A-Za-z0-9]', '', 'g'));
  v_limit  integer := least(greatest(coalesce(p_limit, 500), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_hash   text := public.hub_hash(p_token);
  v_taken  integer;
  v_return integer;
  v_cards  json;
begin
  perform public.hub_touch(v_hash, 30);

  select coalesce(json_agg(t.card), '[]'::json)
    into v_cards
    from (
      select public.hub_card_public(c) as card
        from public.invite_codes c
       where (case v_status
                when 'available' then c.status = 'available'
                when 'used'      then c.status <> 'available'
                else true
              end)
         and (v_query = '' or c.code_norm like '%' || v_query || '%')
       order by (c.created_at >= now() - interval '15 minutes') desc, c.created_at desc
       limit v_limit offset v_offset
    ) t;

  -- 接力状态：接过多少（只算码还在池子里的）、放回多少（未被下架的）
  perform public.hub_autoblock(v_hash);

  select count(*) into v_taken
    from public.reports r
    join public.invite_codes c on c.id = r.code_id
   where r.visitor_hash = v_hash
     and r.action = 'reveal'
     and c.status <> 'expired';

  select count(*) into v_return
    from public.invite_codes
   where creator_hash = v_hash
     and status <> 'expired';

  return json_build_object(
    'ok', true,
    'cards', v_cards,
    'stats', public.hub_stats(),
    'quota', json_build_object(
      'remaining', greatest(0, 2 - (
        select count(*) from public.reports r
         where r.visitor_hash = public.hub_hash(p_token)
           and r.action = 'reveal'
           and ((r.created_at at time zone 'UTC') + interval '8 hours')::date = public.hub_today()
      )),
      'limit', 2,
      'resetAt', '北京时间 00:00'
    ),
    'relay', json_build_object(
      'taken', v_taken,
      'returned', v_return,
      'pending', greatest(0, v_taken - v_return),
      -- 我放回过、但后来被下架/删掉的码：这些不算回填，欠的账还得再放一个
      'voided', (
        select count(*) from public.invite_codes c
         where c.creator_hash = v_hash and c.status = 'expired'
      ),
      'blocked', (v_taken >= v_return + 1) or exists (
        select 1 from public.visitor_blocks b where b.visitor_hash = v_hash
      ),
      'graceMinutes', public.hub_grace_minutes(),
      -- 这台设备最近一次发码申请（前端据此把按钮改成「已申请，等发码」）
      'request', (
        select json_build_object('status', r.status, 'createdAt', r.created_at)
          from public.reveal_requests r
         where r.visitor_hash = v_hash
         order by r.created_at desc limit 1
      )
    )
  );
end;
$$;

-- 搜索不会泄露：搜的是 code_norm，但返回的还是遮罩卡；命中即为"有这么个码"。

-- 收录规则集中在一处：返回不收的理由，合格返回 null。
-- 发布时用它拦，后台「清理不合规」也用它判定，两边口径不会跑偏。
-- 拒收：写一条 reject_log（只留 7 天），再把「为什么没收」返回给前端
create or replace function public.hub_reject(
  p_code    text,
  p_visitor text,
  p_reason  text,
  p_hint    text default ''
)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.reject_log (code_norm, visitor_hash, reason)
  values (left(coalesce(p_code, ''), 32), p_visitor, left(coalesce(p_reason, ''), 120));

  delete from public.reject_log where created_at < now() - interval '7 days';

  return json_build_object('ok', false, 'error', coalesce(p_reason, '') || coalesce(p_hint, ''));
end;
$$;

-- ---------------------------------------------------------------- RPC：发布

create or replace function public.publish_code(
  p_code  text,
  p_spots integer default 1,
  p_token text default ''
)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_norm    text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_spots   integer := coalesce(p_spots, 1);
  v_visitor text := public.hub_hash(p_token);
  v_mine    integer;
  v_recent  integer;
  v_rank    integer;
  v_row     public.invite_codes;
  v_blocked boolean;
  v_problem text;
  v_hint    text := '';
begin
  perform public.hub_touch(v_visitor);

  -- 提交失败一律不算回填：如果这台设备正被限制，提示里说清楚"限制还没解除"
  v_blocked := exists (select 1 from public.visitor_blocks b where b.visitor_hash = v_visitor);
  if v_blocked then
    v_hint := '（这次不算回填，限制还没解除，得重新放一个有效的邀请码）';
  end if;

  -- ---- 格式校验：专收小豆 6 位「字母+数字」码，乱七八糟的一律不收（拒收都进日志）----
  v_problem := public.hub_code_problem(v_norm);
  if v_problem is not null then
    return public.hub_reject(v_norm, v_visitor,
      '本站不收这个码：' || v_problem || '。规矩是 6 位、字母数字都有、不能 3 个连在一起、不带 91/78/13/27', v_hint);
  end if;
  if v_spots < 1 or v_spots > 30 then
    return public.hub_reject(v_norm, v_visitor, '剩余次数必须是 1–30 的整数', v_hint);
  end if;

  select count(*) into v_mine
    from public.invite_codes
   where creator_hash = v_visitor and status = 'available';
  if v_mine >= 1 then
    return public.hub_reject(v_norm, v_visitor,
      '你放回的码还在池子里没人接走，先等它被接走（或等它下架）再放新的', v_hint);
  end if;

  select count(*) into v_recent
    from public.publish_log
   where created_at >= now() - interval '10 minutes';
  if v_recent >= 30 then
    return public.hub_reject(v_norm, v_visitor, '全站发布太频繁，请过几分钟再试', v_hint);
  end if;

  -- 被下架/删除过的码不能拿来抵回填：它已经证明是无效码
  if exists (select 1 from public.invite_codes
              where code_norm = v_norm and status = 'expired') then
    return public.hub_reject(v_norm, v_visitor,
      '这个邀请码之前已经被下架了（无效码），不能拿来抵回填，换一个能用的', v_hint);
  end if;
  if exists (select 1 from public.invite_codes where code_norm = v_norm) then
    return public.hub_reject(v_norm, v_visitor, '该邀请码已经在池里了，换个没放过的', v_hint);
  end if;

  select coalesce(max(queue_rank), 0) + 1 into v_rank from public.invite_codes;

  insert into public.invite_codes
    (code, code_norm, status, total_spots, remaining_spots, claimed_count,
     queue_rank, creator_hash)
  values
    (v_norm, v_norm, 'available', v_spots, v_spots, 0, v_rank, v_visitor)
  returning * into v_row;

  insert into public.publish_log (visitor_hash, code_id) values (v_visitor, v_row.id);

  -- 回填了就自动解除"超时未回填"的限制；管理员手动限制的不动
  delete from public.visitor_blocks
   where visitor_hash = v_visitor and kind = 'auto';

  return json_build_object(
    'ok', true,
    'card', public.hub_card_public(v_row),
    'stats', public.hub_stats()
  );
end;
$$;

-- ---------------------------------------------------------------- RPC：揭晓（唯一出码口）

create or replace function public.reveal_code(
  p_id    uuid,
  p_token text default ''
)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_visitor  text := public.hub_hash(p_token);
  v_row      public.invite_codes;
  v_today_n  integer;
  v_total_n  integer;
  v_pub_n    integer;
  v_hourly   integer;
  v_remaining integer;
begin
  perform public.hub_touch(v_visitor);

  -- 出码方式改成人工发码时，自动揭晓一律关掉（防止有人绕过页面直接抓接口）
  if public.hub_reveal_mode() = 'manual' then
    raise exception '现在不是自动出码：点卡片上的「申请一个码」，站长核对后会私发给你' using errcode = 'P0001';
  end if;

  -- 先把超时未回填的设备自动限制掉（回填后会自动解除）
  perform public.hub_autoblock(v_visitor);

  -- 被管理员限制的设备：直接拒掉，先把欠的码还上
  if exists (select 1 from public.visitor_blocks where visitor_hash = v_visitor) then
    raise exception '这台设备已被限制揭晓：拿到码 % 分钟内没回填就会锁，先把自己的邀请码放回来（放回后自动解锁）',
      public.hub_grace_minutes() using errcode = 'P0001';
  end if;

  select * into v_row from public.invite_codes where id = p_id for update;
  if not found then
    raise exception '这个邀请码不存在了' using errcode = 'P0001';
  end if;
  if v_row.status <> 'available' or v_row.remaining_spots <= 0 then
    raise exception '这个邀请码已经被别人揭晓了' using errcode = 'P0001';
  end if;

  if exists (select 1 from public.reports
              where code_id = p_id and visitor_hash = v_visitor and action = 'reveal') then
    raise exception '你已经揭晓过这个码了' using errcode = 'P0001';
  end if;

  select count(*) into v_today_n
    from public.reports r
   where r.visitor_hash = v_visitor
     and r.action = 'reveal'
     and ((r.created_at at time zone 'UTC') + interval '8 hours')::date = public.hub_today();
  if v_today_n >= 2 then
    raise exception '今天的揭晓次数用完了（每人每天 2 次，北京时间 00:00 重置）' using errcode = 'P0001';
  end if;

  select count(*) into v_hourly
    from public.reports
   where visitor_hash = v_visitor and created_at >= now() - interval '1 hour';
  if v_hourly >= 30 then
    raise exception '操作太频繁，先歇一会儿' using errcode = 'P0001';
  end if;

  -- 免费纯接力：接过 2 个码还没往池子里放过任何一个，就先别接着接了
  -- 只算"码还在池子里/还没被下架"的揭晓：管理员删掉或下架那个码，这笔接力记录就不再算数
  select count(*) into v_total_n
    from public.reports r
    join public.invite_codes c on c.id = r.code_id
   where r.visitor_hash = v_visitor
     and r.action = 'reveal'
     and c.status <> 'expired';
  -- 接力规则：第一个码免费接，之后"接过 N 个"必须至少放回 N-1 个
  -- 只算"还留在池子里、没被管理员下架"的码：发废码占位被发现下架后，解锁同样失效
  select count(*) into v_pub_n
    from public.invite_codes
   where creator_hash = v_visitor
     and status <> 'expired';
  if v_total_n >= v_pub_n + 1 then
    raise exception '接力规则：你已经接过 % 个邀请码，只放回 % 个。先把自己的邀请码分享进来，才能继续揭晓',
      v_total_n, v_pub_n using errcode = 'P0001';
  end if;

  v_remaining := v_row.remaining_spots - 1;

  update public.invite_codes
     set remaining_spots = v_remaining,
         claimed_count   = claimed_count + 1,
         status          = case when v_remaining <= 0 then 'used' else 'available' end,
         updated_at      = now()
   where id = p_id
  returning * into v_row;

  insert into public.reports (code_id, action, visitor_hash) values (p_id, 'reveal', v_visitor);

  return json_build_object(
    'ok', true,
    'code', v_row.code,
    'card', public.hub_card_full(v_row),
    'stats', public.hub_stats(),
    'quotaRemaining', greatest(0, 2 - (v_today_n + 1))
  );
end;
$$;

-- ---------------------------------------------------------------- RPC：反馈

create or replace function public.submit_feedback(
  p_id     uuid,
  p_reason text,
  p_note   text default '',
  p_token  text default ''
)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_visitor text := public.hub_hash(p_token);
  v_row     public.invite_codes;
  v_today   integer;
  v_reports integer;
begin
  perform public.hub_touch(v_visitor);

  select * into v_row from public.invite_codes where id = p_id;
  if not found then
    raise exception '邀请码不存在' using errcode = 'P0001';
  end if;
  if p_reason not in ('invalid', 'used', 'wrong_info', 'other') then
    raise exception '反馈原因不合法' using errcode = 'P0001';
  end if;

  select count(*) into v_today
    from public.feedback
   where visitor_hash = v_visitor and created_at >= now() - interval '1 day';
  if v_today >= 10 then
    raise exception '今天的反馈次数用完了' using errcode = 'P0001';
  end if;

  if exists (select 1 from public.feedback
              where code_id = p_id and visitor_hash = v_visitor and reason = p_reason) then
    raise exception '你已经反馈过同样的原因了' using errcode = 'P0001';
  end if;

  insert into public.feedback (code_id, code, reason, note, visitor_hash)
  values (p_id, v_row.code, p_reason, left(coalesce(p_note, ''), 300), v_visitor);

  -- 自动下架：同一个码被 2 个不同的人举报（任意原因），先摘出池子等人工核验
  select count(distinct f.visitor_hash) into v_reports
    from public.feedback f
   where f.code_id = p_id;
  if v_reports >= 2 and v_row.status = 'available' then
    update public.invite_codes
       set status = 'expired', updated_at = now()
     where id = p_id;
  end if;

  return json_build_object('ok', true, 'autoClosed', v_reports >= 2);
end;
$$;

-- ---------------------------------------------------------------- RPC：管理（可看明文）

create or replace function public.admin_verify(p_key text)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.hub_require_admin(p_key);
  return json_build_object('ok', true);
end;
$$;

create or replace function public.admin_find(p_code text, p_key text)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_norm text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_row  public.invite_codes;
begin
  perform public.hub_require_admin(p_key);
  select * into v_row from public.invite_codes where code_norm = v_norm;
  if not found then
    raise exception '池子里没有这个邀请码' using errcode = 'P0001';
  end if;
  return json_build_object('ok', true, 'card', public.hub_card_full(v_row));
end;
$$;

create or replace function public.admin_update(
  p_id        uuid,
  p_key       text,
  p_remaining integer default null,
  p_position  integer default null,
  p_status    text    default null
)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row     public.invite_codes;
  v_total   integer;
  v_status  text;
  v_remain  integer;
  v_pos     integer;
begin
  perform public.hub_require_admin(p_key);

  select * into v_row from public.invite_codes where id = p_id for update;
  if not found then
    raise exception '邀请码不存在' using errcode = 'P0001';
  end if;

  v_remain := coalesce(p_remaining, v_row.remaining_spots);

  if v_remain < 0 or v_remain > 30 then
    raise exception '剩余次数只能是 0–30' using errcode = 'P0001';
  end if;

  -- 显式传状态就照做（下架用的就是这条），没传才按剩余次数推断
  if p_status is not null and length(trim(p_status)) > 0 then
    v_status := trim(p_status);
    if v_status not in ('available', 'used', 'expired') then
      raise exception '状态不合法' using errcode = 'P0001';
    end if;
    if v_status = 'available' and v_remain = 0 then
      v_status := 'used';
    end if;
  else
    v_status := v_row.status;
    if v_remain = 0 then
      v_status := 'used';
    elsif v_status = 'used' then
      v_status := 'available';
    end if;
  end if;

  if p_position is not null then
    select count(*) into v_total from public.invite_codes;
    v_pos := least(greatest(p_position, 1), v_total);
    perform pg_advisory_xact_lock(778899);

    with ordered as (
      select id,
             row_number() over (
               order by case when id = p_id then v_pos
                             when queue_rank < v_pos then queue_rank
                             else queue_rank + 1 end,
                        created_at
             ) as rn
        from public.invite_codes
    )
    update public.invite_codes c
       set queue_rank = o.rn, updated_at = now()
      from ordered o
     where c.id = o.id;
  end if;

  update public.invite_codes
     set remaining_spots = v_remain, status = v_status, updated_at = now()
   where id = p_id
  returning * into v_row;

  return json_build_object('ok', true, 'card', public.hub_card_full(v_row), 'stats', public.hub_stats());
end;
$$;

create or replace function public.admin_reseed(p_key text)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.hub_require_admin(p_key);
  perform pg_advisory_xact_lock(778899);
  update public.invite_codes c
     set queue_rank = s.rn, updated_at = now()
    from (select id, row_number() over (order by queue_rank, created_at) as rn
            from public.invite_codes) s
   where c.id = s.id;
  return json_build_object('ok', true, 'stats', public.hub_stats());
end;
$$;

-- ---------------------------------------------------------------- RPC：管理后台（列表 / 删除 / 举报）

create or replace function public.admin_list(
  p_key    text,
  p_status text default 'all',
  p_limit  integer default 500
)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status text := coalesce(nullif(trim(p_status), ''), 'all');
  v_limit  integer := least(greatest(coalesce(p_limit, 500), 1), 500);
  v_cards  json;
  v_reports json;
begin
  perform public.hub_require_admin(p_key);

  select coalesce(json_agg(t.card order by t.queue_rank asc, t.created_at asc), '[]'::json)
    into v_cards
    from (
      select public.hub_card_full(c) as card, c.queue_rank, c.created_at
        from public.invite_codes c
       where (case v_status
                when 'available' then c.status = 'available'
                when 'closed'    then c.status <> 'available'
                else true
              end)
       limit v_limit
    ) t;

  select coalesce(json_agg(json_build_object(
           'id',          f.id,
           'codeId',      f.code_id,
           'code',        f.code,
           'reason',      f.reason,
           'note',        f.note,
           'resolved',    f.resolved,
           'createdAt',   f.created_at
         ) order by f.created_at desc), '[]'::json)
    into v_reports
    from public.feedback f
   where f.resolved = false
   limit 100;

  return json_build_object(
    'ok', true,
    'cards', v_cards,
    'reports', v_reports,
    'stats', public.hub_stats(),
    'today', json_build_object(
      'reveals', (select count(*) from public.reports r
                   where r.action = 'reveal'
                     and ((r.created_at at time zone 'UTC') + interval '8 hours')::date = public.hub_today()),
      'publishes', (select count(*) from public.publish_log p
                     where ((p.created_at at time zone 'UTC') + interval '8 hours')::date = public.hub_today()),
      'newCodes', (select count(*) from public.invite_codes c
                    where ((c.created_at at time zone 'UTC') + interval '8 hours')::date = public.hub_today())
    )
  );
end;
$$;

create or replace function public.admin_delete_code(p_id uuid, p_key text)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.hub_require_admin(p_key);
  perform pg_advisory_xact_lock(778899);

  delete from public.invite_codes where id = p_id;
  if not found then
    raise exception '邀请码不存在' using errcode = 'P0001';
  end if;

  update public.invite_codes c
     set queue_rank = s.rn, updated_at = now()
    from (select id, row_number() over (order by queue_rank, created_at) as rn
            from public.invite_codes) s
   where c.id = s.id;

  return json_build_object('ok', true, 'stats', public.hub_stats());
end;
$$;

create or replace function public.admin_clear_codes(p_key text)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n integer;
begin
  perform public.hub_require_admin(p_key);
  perform pg_advisory_xact_lock(778899);

  select count(*) into v_n from public.invite_codes;

  delete from public.feedback f
   where f.code_id is not null
     and exists (select 1 from public.invite_codes c where c.id = f.code_id);

  delete from public.reports r
   where exists (select 1 from public.invite_codes c where c.id = r.code_id);

  delete from public.invite_codes where id is not null;

  return json_build_object('ok', true, 'removed', v_n, 'stats', public.hub_stats());
end;
$$;

-- 清理不合规的码：按 hub_code_problem 统一判定，合格的留着，不合规的一律下架
-- 用「下架」而不是「删除」：码和领取记录都还在，只是不再能揭晓，误杀还能在码表里恢复
create or replace function public.admin_purge_bad(p_key text, p_apply boolean default false)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_list    json;
  v_n       integer;
  v_removed integer := 0;
begin
  perform public.hub_require_admin(p_key);

  select coalesce(json_agg(t.code_norm order by t.created_at), '[]'::json)
    into v_list
    from public.invite_codes t
   where t.status <> 'expired' and public.hub_code_problem(t.code_norm) is not null;
  v_n := json_array_length(v_list);

  if coalesce(p_apply, false) and v_n > 0 then
    perform pg_advisory_xact_lock(778899);
    update public.invite_codes
       set status = 'expired', updated_at = now()
     where status <> 'expired' and public.hub_code_problem(code_norm) is not null;
    get diagnostics v_removed = row_count;
  end if;

  return json_build_object('ok', true, 'found', v_n, 'codes', v_list, 'removed', v_removed,
                           'stats', public.hub_stats());
end;
$$;

create or replace function public.admin_resolve_report(
  p_id      bigint,
  p_key     text,
  p_resolve boolean default true
)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.hub_require_admin(p_key);
  update public.feedback set resolved = coalesce(p_resolve, true) where id = p_id;
  if not found then
    raise exception '这条举报不存在' using errcode = 'P0001';
  end if;
  return json_build_object('ok', true);
end;
$$;

create or replace function public.admin_set_key(p_key text, p_new_key text)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.hub_require_admin(p_key);
  if p_new_key is null or length(trim(p_new_key)) < 8 then
    raise exception '新密码至少 8 位' using errcode = 'P0001';
  end if;
  update public.app_settings
     set admin_token_hash = encode(sha256(convert_to(trim(p_new_key), 'UTF8')), 'hex'),
         updated_at = now()
   where id = true;
  return json_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------- RPC：接力账本（仅管理员）

-- 按设备指纹列账：揭晓几个、回填几个、欠几个、最后活跃时间、是否被限制
create or replace function public.admin_ledger(
  p_key           text,
  p_limit         integer default 300,
  p_only_pending  boolean default false
)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 300), 1), 1000);
begin
  perform public.hub_require_admin(p_key);

  return (
    with rv as (
      select r.visitor_hash as vh, count(*) as taken, max(r.created_at) as last_rev,
             (array_agg(c.code_norm order by r.created_at desc))[1:8] as got
        from public.reports r
        join public.invite_codes c on c.id = r.code_id
       where r.action = 'reveal' and c.status <> 'expired'
       group by 1
    ),
    pb as (
      select c.creator_hash as vh, count(*) as returned, max(c.created_at) as last_pub,
             (array_agg(c.code_norm order by c.created_at desc))[1:8] as gave
        from public.invite_codes c
       where c.creator_hash is not null and c.status <> 'expired'
       group by 1
    ),
    v as (
      select vh from rv union select vh from pb
    ),
    agg as (
      select v.vh,
             coalesce(rv.taken, 0) as taken,
             coalesce(pb.returned, 0) as returned,
             greatest(coalesce(rv.taken, 0) - coalesce(pb.returned, 0), 0) as pending,
             greatest(coalesce(rv.last_rev, to_timestamp(0)),
                      coalesce(pb.last_pub, to_timestamp(0))) as last_at,
             rv.got, pb.gave,
             b.visitor_hash is not null as blocked,
             coalesce(b.kind, '') as block_kind,
             b.note
        from v
        left join rv on rv.vh = v.vh
        left join pb on pb.vh = v.vh
        left join public.visitor_blocks b on b.visitor_hash = v.vh
    )
    select coalesce(json_agg(
             json_build_object(
               'hash',    a.vh,
               'short',   left(a.vh, 8),
               'taken',   a.taken,
               'returned', a.returned,
               'pending', a.pending,
               'gotCodes', coalesce(to_json(a.got), '[]'::json),
               'gaveCodes', coalesce(to_json(a.gave), '[]'::json),
               'lastAt',  case when a.last_at = to_timestamp(0) then null else a.last_at end,
               'blocked', a.blocked,
               'blockKind', a.block_kind,
               'note',    a.note
             )
             order by a.pending desc, a.last_at desc
           ), '[]'::json)
      from (select * from agg
             where (not coalesce(p_only_pending, false)) or pending > 0
             order by pending desc, last_at desc
             limit v_limit) a
  );
end;
$$;

-- 拉黑：可按完整指纹，也可只给前几位（要求唯一命中）
create or replace function public.admin_block(
  p_key   text,
  p_hash  text,
  p_note  text default ''
)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_in    text := lower(trim(coalesce(p_hash, '')));
  v_full  text;
  v_hits  integer;
begin
  perform public.hub_require_admin(p_key);
  if length(v_in) < 6 then
    raise exception '指纹至少 6 位' using errcode = 'P0001';
  end if;

  select count(distinct vh) into v_hits
    from (
      select r.visitor_hash as vh from public.reports r
      union
      select c.creator_hash as vh from public.invite_codes c where c.creator_hash is not null
    ) t
   where t.vh = v_in or t.vh like v_in || '%';

  if v_hits = 0 then
    raise exception '找不到这个设备指纹' using errcode = 'P0001';
  end if;
  if v_hits > 1 then
    raise exception '这个短码对应 % 个设备，输完整指纹，或直接点表里的「限制」', v_hits using errcode = 'P0001';
  end if;

  select vh into v_full
    from (
      select r.visitor_hash as vh from public.reports r
      union
      select c.creator_hash as vh from public.invite_codes c where c.creator_hash is not null
    ) t
   where t.vh = v_in or t.vh like v_in || '%'
   limit 1;

  insert into public.visitor_blocks (visitor_hash, note)
  values (v_full, nullif(trim(coalesce(p_note, '')), ''))
  on conflict (visitor_hash) do update
    set note = coalesce(excluded.note, public.visitor_blocks.note);

  return json_build_object('ok', true, 'hash', left(v_full, 8));
end;
$$;

create or replace function public.admin_unblock(
  p_key  text,
  p_hash text
)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_in   text := lower(trim(coalesce(p_hash, '')));
  v_full text;
  v_hits integer;
begin
  perform public.hub_require_admin(p_key);
  if length(v_in) < 6 then
    raise exception '指纹至少 6 位' using errcode = 'P0001';
  end if;

  select count(distinct vh) into v_hits
    from (
      select r.visitor_hash as vh from public.reports r
      union
      select c.creator_hash as vh from public.invite_codes c where c.creator_hash is not null
      union
      select b.visitor_hash as vh from public.visitor_blocks b
    ) t
   where t.vh = v_in or t.vh like v_in || '%';

  if v_hits = 0 then
    raise exception '找不到这个设备指纹' using errcode = 'P0001';
  end if;
  if v_hits > 1 then
    raise exception '这个短码对应 % 个设备，输完整指纹', v_hits using errcode = 'P0001';
  end if;

  select vh into v_full
    from (
      select r.visitor_hash as vh from public.reports r
      union
      select c.creator_hash as vh from public.invite_codes c where c.creator_hash is not null
      union
      select b.visitor_hash as vh from public.visitor_blocks b
    ) t
   where t.vh = v_in or t.vh like v_in || '%'
   limit 1;

  delete from public.visitor_blocks where visitor_hash = v_full;
  if not found then
    raise exception '这个设备本来就没被限制' using errcode = 'P0001';
  end if;

  return json_build_object('ok', true, 'hash', left(v_full, 8));
end;
$$;

create or replace function public.admin_settings(p_key text)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.hub_require_admin(p_key);
  return json_build_object(
    'graceMinutes', public.hub_grace_minutes(),
    'revealMode',   public.hub_reveal_mode(),
    'wm', (
      select json_build_object(
        'line1', wm_line1, 'line2', wm_line2, 'opacity', wm_opacity
      ) from public.app_settings where id = true
    )
  );
end;
$$;

-- 水印：改字、改深浅，改完首页刷新就变，不用重新部署
create or replace function public.admin_set_watermark(
  p_key     text,
  p_line1   text,
  p_line2   text,
  p_opacity numeric
)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_op numeric := least(greatest(coalesce(p_opacity, 0.11), 0), 0.35);
begin
  perform public.hub_require_admin(p_key);
  update public.app_settings
     set wm_line1   = left(coalesce(nullif(trim(p_line1), ''), '自觉回填邀请码'), 40),
         wm_line2   = left(coalesce(nullif(trim(p_line2), ''), '拿码不回 · 限制设备'), 40),
         wm_opacity = v_op,
         updated_at = now()
   where id = true;
  return json_build_object(
    'ok', true,
    'wm', (select json_build_object('line1', wm_line1, 'line2', wm_line2, 'opacity', wm_opacity)
             from public.app_settings where id = true)
  );
end;
$$;

create or replace function public.admin_set_autoblock(p_key text, p_minutes integer)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.hub_require_admin(p_key);
  if p_minutes is null or p_minutes < 0 or p_minutes > 1440 then
    raise exception '分钟数要在 0–1440 之间（0 = 关闭自动限制）' using errcode = 'P0001';
  end if;
  update public.app_settings
     set autoblock_minutes = p_minutes, updated_at = now()
   where id = true;
  return json_build_object('ok', true, 'graceMinutes', p_minutes);
end;
$$;

-- 被拒收的提交：后台看规则有没有误杀真码
create or replace function public.admin_rejects(p_key text, p_limit integer default 100)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 500);
begin
  perform public.hub_require_admin(p_key);
  return json_build_object(
    'total', (select count(*) from public.reject_log),
    'today', (select count(*) from public.reject_log
               where ((created_at at time zone 'UTC') + interval '8 hours')::date = public.hub_today()),
    'byReason', (
      select coalesce(json_agg(json_build_object('reason', reason, 'n', n) order by n desc), '[]'::json)
        from (select reason, count(*) as n from public.reject_log group by reason) t
    ),
    'rows', (
      select coalesce(json_agg(json_build_object(
          'code', code_norm, 'reason', reason,
          'who', substr(coalesce(visitor_hash, ''), 1, 8), 'at', created_at
        ) order by created_at desc), '[]'::json)
        from (select * from public.reject_log order by created_at desc limit v_limit) t
    )
  );
end;
$$;

create or replace function public.admin_clear_rejects(p_key text)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n integer;
begin
  perform public.hub_require_admin(p_key);
  delete from public.reject_log where id > 0;
  get diagnostics v_n = row_count;
  return json_build_object('ok', true, 'removed', v_n);
end;
$$;

-- ---------------------------------------------------------------- 函数授权

revoke all on function public.hub_stats() from public;
revoke all on function public.list_codes(text, text, integer, integer, text) from public;
revoke all on function public.publish_code(text, integer, text) from public;
revoke all on function public.reveal_code(uuid, text) from public;
revoke all on function public.submit_feedback(uuid, text, text, text) from public;
revoke all on function public.admin_verify(text) from public;
revoke all on function public.admin_find(text, text) from public;
revoke all on function public.admin_update(uuid, text, integer, integer, text) from public;
revoke all on function public.admin_reseed(text) from public;
revoke all on function public.admin_list(text, text, integer) from public;
revoke all on function public.admin_delete_code(uuid, text) from public;
revoke all on function public.admin_clear_codes(text) from public;
revoke all on function public.admin_resolve_report(bigint, text, boolean) from public;
revoke all on function public.admin_set_key(text, text) from public;
revoke all on function public.admin_ledger(text, integer, boolean) from public;
revoke all on function public.admin_block(text, text, text) from public;
revoke all on function public.admin_unblock(text, text) from public;
revoke all on function public.admin_settings(text) from public;
revoke all on function public.admin_set_autoblock(text, integer) from public;
revoke all on function public.admin_set_watermark(text, text, text, numeric) from public;
revoke all on function public.admin_rejects(text, integer) from public;
revoke all on function public.admin_clear_rejects(text) from public;
revoke all on function public.admin_purge_bad(text, boolean) from public;
revoke all on function public.hub_reject(text, text, text, text) from public;
revoke all on function public.hub_code_problem(text) from public;

grant execute on function public.hub_stats() to anon, authenticated;
grant execute on function public.list_codes(text, text, integer, integer, text) to anon, authenticated;
grant execute on function public.publish_code(text, integer, text) to anon, authenticated;
grant execute on function public.reveal_code(uuid, text) to anon, authenticated;
grant execute on function public.submit_feedback(uuid, text, text, text) to anon, authenticated;
grant execute on function public.admin_verify(text) to anon, authenticated;
grant execute on function public.admin_find(text, text) to anon, authenticated;
grant execute on function public.admin_update(uuid, text, integer, integer, text) to anon, authenticated;
grant execute on function public.admin_reseed(text) to anon, authenticated;
grant execute on function public.admin_list(text, text, integer) to anon, authenticated;
grant execute on function public.admin_delete_code(uuid, text) to anon, authenticated;
grant execute on function public.admin_clear_codes(text) to anon, authenticated;
grant execute on function public.admin_resolve_report(bigint, text, boolean) to anon, authenticated;
grant execute on function public.admin_set_key(text, text) to anon, authenticated;
grant execute on function public.admin_ledger(text, integer, boolean) to anon, authenticated;
grant execute on function public.admin_block(text, text, text) to anon, authenticated;
grant execute on function public.admin_unblock(text, text) to anon, authenticated;
grant execute on function public.admin_settings(text) to anon, authenticated;
grant execute on function public.admin_set_autoblock(text, integer) to anon, authenticated;
grant execute on function public.admin_set_watermark(text, text, text, numeric) to anon, authenticated;
grant execute on function public.admin_rejects(text, integer) to anon, authenticated;
grant execute on function public.admin_clear_rejects(text) to anon, authenticated;
grant execute on function public.admin_purge_bad(text, boolean) to anon, authenticated;




-- ---------------------------------------------------------------- RPC：申请制发码（防跑路）

-- 当事人提交申请：留个能联系上的方式，站长核对后再私发码
create or replace function public.request_code(
  p_token   text,
  p_contact text default '',
  p_note    text default ''
)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_hash    text := public.hub_hash(p_token);
  v_contact text := left(btrim(coalesce(p_contact, '')), 80);
  v_note    text := left(btrim(coalesce(p_note, '')), 200);
  v_taken   integer;
  v_ret     integer;
  v_today   integer;
  v_open    bigint;
  v_id      bigint;
begin
  perform public.hub_touch(v_hash);

  if length(v_contact) < 4 then
    return json_build_object('ok', false, 'error', '留个能联系上的方式吧（微信 / QQ / 邮箱都行），不然码发不到你手上');
  end if;

  if exists (select 1 from public.visitor_blocks where visitor_hash = v_hash) then
    return json_build_object('ok', false, 'error', '这台设备现在被限制着：先把欠的邀请码放回来，再来申请');
  end if;

  select count(*) into v_taken
    from public.reports r
    join public.invite_codes c on c.id = r.code_id
   where r.visitor_hash = v_hash and r.action = 'reveal' and c.status <> 'expired';
  select count(*) into v_ret
    from public.invite_codes where creator_hash = v_hash and status <> 'expired';
  if v_taken > v_ret then
    return json_build_object('ok', false, 'error', '你手里还欠着 ' || (v_taken - v_ret) || ' 个没还：先把邀请码放回来，再来申请');
  end if;

  select id into v_open from public.reveal_requests
   where visitor_hash = v_hash and status = 'open' limit 1;
  if v_open is not null then
    return json_build_object('ok', false, 'error', '你上次的申请还在等站长处理，别重复交');
  end if;

  select count(*) into v_today from public.reveal_requests
   where visitor_hash = v_hash
     and ((created_at at time zone 'UTC') + interval '8 hours')::date = public.hub_today();
  if v_today >= 2 then
    return json_build_object('ok', false, 'error', '今天已经申请过 ' || v_today || ' 次了，明天再来');
  end if;

  insert into public.reveal_requests (visitor_hash, contact, note)
  values (v_hash, v_contact, v_note)
  returning id into v_id;

  return json_build_object('ok', true, 'id', v_id,
    'position', (select count(*) from public.reveal_requests where status = 'open' and created_at < now()));
end;
$$;

-- 后台：待发码申请列表（带这人揭了几、回了几、欠几）
create or replace function public.admin_requests(p_key text)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.hub_require_admin(p_key);

  return (
    with rq as (
      select r.id, r.visitor_hash as vh, r.contact, r.note, r.status, r.created_at
        from public.reveal_requests r
       where r.status = 'open'
       order by r.created_at
       limit 200
    ),
    rd as (
      select rq.*,
             (select count(*) from public.reports x
               join public.invite_codes c on c.id = x.code_id
              where x.visitor_hash = rq.vh and x.action = 'reveal' and c.status <> 'expired') as taken,
             (select count(*) from public.invite_codes c2
              where c2.creator_hash = rq.vh and c2.status <> 'expired') as returned,
             exists (select 1 from public.visitor_blocks b where b.visitor_hash = rq.vh) as blocked
        from rq
    )
    select json_build_object(
      'ok', true,
      'openCount', (select count(*) from rd),
      'available', (select count(*) from public.invite_codes where status = 'available'),
      'rows', (select coalesce(json_agg(json_build_object(
                 'id', rd.id,
                 'short', left(rd.vh, 8),
                 'contact', rd.contact,
                 'note', rd.note,
                 'createdAt', rd.created_at,
                 'taken', rd.taken,
                 'returned', rd.returned,
                 'pending', greatest(rd.taken - rd.returned, 0),
                 'blocked', rd.blocked
               ) order by rd.created_at), '[]'::json) from rd)
    )
  );
end;
$$;

-- 后台：给某条申请发一个码（默认取池子里顺位最前的那条），返回明文给管理员自己去发
create or replace function public.admin_send_code(
  p_key     text,
  p_id      bigint,
  p_code_id uuid default null
)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_req  public.reveal_requests;
  v_row  public.invite_codes;
begin
  perform public.hub_require_admin(p_key);

  select * into v_req from public.reveal_requests where id = p_id for update;
  if not found then
    return json_build_object('ok', false, 'error', '这条申请不存在');
  end if;
  if v_req.status <> 'open' then
    return json_build_object('ok', false, 'error', '这条申请已经处理过了');
  end if;

  if p_code_id is not null then
    select * into v_row from public.invite_codes where id = p_code_id for update;
  else
    select * into v_row from public.invite_codes
     where status = 'available' order by queue_rank, created_at limit 1 for update;
  end if;

  if not found or v_row.status <> 'available' then
    return json_build_object('ok', false, 'error', '池子里没有可发的码，先让人放一个进来');
  end if;

  perform pg_advisory_xact_lock(778900);

  update public.invite_codes
     set status = 'used', remaining_spots = 0,
         claimed_count = claimed_count + 1, updated_at = now()
   where id = v_row.id;

  insert into public.reports (code_id, action, visitor_hash)
  values (v_row.id, 'reveal', v_req.visitor_hash)
  on conflict (code_id, visitor_hash, action) do nothing;

  update public.reveal_requests
     set status = 'sent', code_id = v_row.id, handled_at = now()
   where id = p_id;

  return json_build_object('ok', true, 'code', v_row.code, 'to', left(v_req.visitor_hash, 8),
                           'contact', v_req.contact, 'requestId', p_id);
end;
$$;

-- 后台：拒绝 / 关闭一条申请
create or replace function public.admin_resolve_request(
  p_key  text,
  p_id   bigint,
  p_note text default ''
)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.hub_require_admin(p_key);

  update public.reveal_requests
     set status = 'rejected', handled_at = now(),
         note = left(btrim(coalesce(note, '') || case when coalesce(p_note, '') = '' then '' else '｜' || left(p_note, 120) end), 200)
   where id = p_id and status = 'open';

  if not found then
    return json_build_object('ok', false, 'error', '这条申请不存在或已经处理过');
  end if;
  return json_build_object('ok', true);
end;
$$;

-- 后台：切回自动揭晓 / 继续人工发码
create or replace function public.admin_set_reveal_mode(p_key text, p_mode text)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v text := lower(btrim(coalesce(p_mode, '')));
begin
  perform public.hub_require_admin(p_key);
  if v not in ('auto', 'manual') then
    return json_build_object('ok', false, 'error', '只认 auto 或 manual');
  end if;
  update public.app_settings set reveal_mode = v, updated_at = now() where id = true;
  return json_build_object('ok', true, 'mode', v);
end;
$$;

revoke all on function public.request_code(text, text, text) from public;
revoke all on function public.admin_requests(text) from public;
revoke all on function public.admin_send_code(text, bigint, uuid) from public;
revoke all on function public.admin_resolve_request(text, bigint, text) from public;
revoke all on function public.admin_set_reveal_mode(text, text) from public;

grant execute on function public.request_code(text, text, text) to anon, authenticated;
grant execute on function public.admin_requests(text) to anon, authenticated;
grant execute on function public.admin_send_code(text, bigint, uuid) to anon, authenticated;
grant execute on function public.admin_resolve_request(text, bigint, text) to anon, authenticated;
grant execute on function public.admin_set_reveal_mode(text, text) to anon, authenticated;

-- 欠码公示：公开接口，只出脱敏信息（城市 + 掩码 IP + 设备短标签 + 欠几个）
-- 不出完整指纹、不出完整 IP、不出完整联系方式
create or replace function public.public_debts(p_limit integer default 40)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 40), 1), 100);
begin
  return (
    with rv as (
      select r.visitor_hash as vh,
             count(*) as taken,
             (array_agg(c.code_norm order by r.created_at desc))[1:1] as got,
             max(r.created_at) as last_rev
        from public.reports r
        join public.invite_codes c on c.id = r.code_id
       where r.action = 'reveal' and c.status <> 'expired'
       group by 1
    ),
    pb as (
      select c.creator_hash as vh, count(*) as returned
        from public.invite_codes c
       where c.creator_hash is not null and c.status <> 'expired'
       group by 1
    ),
    v as (
      select vh from rv union select vh from pb
    ),
    agg as (
      select v.vh,
             coalesce(rv.taken, 0) as taken,
             coalesce(pb.returned, 0) as returned,
             greatest(coalesce(rv.taken, 0) - coalesce(pb.returned, 0), 0) as pending,
             rv.got,
             rv.last_rev
        from v
        left join rv on rv.vh = v.vh
        left join pb on pb.vh = v.vh
    )
    select coalesce(json_agg(
             json_build_object(
               'short',    left(a.vh, 8),
               'city',     coalesce(nullif(m.city, ''), ''),
               'ipMasked', coalesce(nullif(m.ip_masked, ''), ''),
               'ua',       coalesce(nullif(m.ua_short, ''), ''),
               'pending',  a.pending,
               'lastAt',   a.last_rev,
               'lastCode', case
                             when a.got is null or a.got[1] is null then null
                             else overlay(a.got[1] placing '••' from 3 for 2)
                           end,
               'blocked',  exists (select 1 from public.visitor_blocks b where b.visitor_hash = a.vh)
             )
             order by a.pending desc, a.last_rev desc nulls last
           ), '[]'::json)
      from (select * from agg
             where pending > 0
             order by pending desc, last_rev desc nulls last
             limit v_limit) a
      left join public.visitor_meta m on m.visitor_hash = a.vh
  );
end;
$$;

-- 后台：拿设备档案（含完整 IP，只在后台出现，用来批量解析城市）
create or replace function public.admin_meta(p_key text, p_limit integer default 200)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 1000);
begin
  perform public.hub_require_admin(p_key);

  return (
    select coalesce(json_agg(
             json_build_object(
               'hash',    m.visitor_hash,
               'short',   left(m.visitor_hash, 8),
               'ip',      host(m.ip_full),
               'ipMasked', coalesce(m.ip_masked, ''),
               'city',    coalesce(m.city, ''),
               'ua',      coalesce(m.ua_short, ''),
               'firstSeen', m.first_seen,
               'lastSeen',  m.last_seen,
               'hits',    m.hits
             )
             order by m.last_seen desc
           ), '[]'::json)
      from (select * from public.visitor_meta
             order by last_seen desc
             limit v_limit) m
  );
end;
$$;

-- 后台：把解析出来的城市写回（p_map 形如 [{"hash":"…","city":"甘肃省白银市"}])
create or replace function public.admin_set_cities(p_key text, p_map jsonb)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n integer := 0;
begin
  perform public.hub_require_admin(p_key);

  if p_map is null or jsonb_typeof(p_map) <> 'array' then
    return json_build_object('ok', false, 'error', '要一个数组');
  end if;

  with src as (
    select left(btrim(x ->> 'hash'), 64) as h,
           left(btrim(x ->> 'city'), 60) as c
      from jsonb_array_elements(p_map) x
     where coalesce(btrim(x ->> 'city'), '') <> ''
  )
  update public.visitor_meta m
     set city = s.c, city_at = now()
    from src s
   where m.visitor_hash = s.h;
  get diagnostics v_n = row_count;

  return json_build_object('ok', true, 'updated', v_n);
end;
$$;

revoke all on function public.public_debts(integer) from public;
revoke all on function public.admin_meta(text, integer) from public;
revoke all on function public.admin_set_cities(text, jsonb) from public;

grant execute on function public.public_debts(integer) to anon, authenticated;
grant execute on function public.admin_meta(text, integer) to anon, authenticated;
grant execute on function public.admin_set_cities(text, jsonb) to anon, authenticated;

-- ---------------------------------------------------------------- 在线客服

-- 访客：拉自己的会话（没有就返回空），p_after 之后的新消息
create or replace function public.chat_fetch(p_token text, p_after bigint default 0)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_hash text := public.hub_hash(p_token);
  v_th   public.chat_threads;
begin
  select * into v_th from public.chat_threads where visitor_hash = v_hash;
  if not found then
    return json_build_object('thread', null, 'messages', '[]'::json, 'unread', 0);
  end if;

  -- 访客看过就算读过
  update public.chat_threads set unread_visitor = 0 where id = v_th.id;

  return json_build_object(
    'thread', json_build_object(
      'id', v_th.id, 'status', v_th.status, 'createdAt', v_th.created_at
    ),
    'messages', coalesce((
      select json_agg(json_build_object(
               'id', m.id, 'side', m.side, 'body', m.body, 'at', m.created_at
             ) order by m.id)
        from public.chat_messages m
       where m.thread_id = v_th.id and m.id > coalesce(p_after, 0)
    ), '[]'::json),
    'unread', v_th.unread_visitor
  );
end;
$$;

-- 访客：发一条（第一句自动开会话）
create or replace function public.chat_send(p_token text, p_body text, p_nickname text default '')
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_hash text := public.hub_hash(p_token);
  v_body text := left(btrim(coalesce(p_body, '')), 500);
  v_nick text := left(btrim(coalesce(p_nickname, '')), 20);
  v_th   public.chat_threads;
  v_id   bigint;
  v_recent integer;
  v_meta public.visitor_meta;
begin
  if length(v_body) < 1 then
    return json_build_object('ok', false, 'error', '写点什么再发');
  end if;

  perform public.hub_touch(v_hash, 5);

  select * into v_th from public.chat_threads where visitor_hash = v_hash;
  if found and v_th.status = 'closed' then
    return json_build_object('ok', false, 'error', '这个会话已经关了，隔天再来或者直接发邮件');
  end if;

  -- 防刷：一分钟最多 8 条
  if found then
    select count(*) into v_recent from public.chat_messages
     where thread_id = v_th.id and side = 'visitor'
       and created_at > now() - interval '1 minute';
    if v_recent >= 8 then
      return json_build_object('ok', false, 'error', '发太快了，歇一分钟再说');
    end if;
  end if;

  if not found then
    select * into v_meta from public.visitor_meta where visitor_hash = v_hash;
    insert into public.chat_threads (visitor_hash, nickname, city, unread_admin, last_at)
    values (v_hash, nullif(v_nick, ''), coalesce(v_meta.city, ''), 1, now())
    returning * into v_th;
  else
    update public.chat_threads
       set unread_admin = unread_admin + 1,
           last_at = now(),
           nickname = coalesce(nullif(v_nick, ''), nickname),
           city = coalesce(nullif((select city from public.visitor_meta where visitor_hash = v_hash), ''), city)
     where id = v_th.id
    returning * into v_th;
  end if;

  insert into public.chat_messages (thread_id, side, body)
  values (v_th.id, 'visitor', v_body)
  returning id into v_id;

  return json_build_object('ok', true, 'threadId', v_th.id, 'messageId', v_id);
end;
$$;

-- 后台：会话列表
create or replace function public.admin_chat_list(p_key text, p_limit integer default 100)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 500);
begin
  perform public.hub_require_admin(p_key);

  return (
    select coalesce(json_agg(json_build_object(
             'id', t.id,
             'short', left(t.visitor_hash, 8),
             'nickname', coalesce(t.nickname, ''),
             'city', coalesce(t.city, ''),
             'status', t.status,
             'unread', t.unread_admin,
             'lastAt', t.last_at,
             'lastBody', coalesce((
               select left(m.body, 60) from public.chat_messages m
                where m.thread_id = t.id order by m.id desc limit 1), ''),
             'count', (select count(*) from public.chat_messages m where m.thread_id = t.id),
             'ua', coalesce((select ua_short from public.visitor_meta v where v.visitor_hash = t.visitor_hash), '')
           ) order by t.unread_admin desc, t.last_at desc), '[]'::json)
      from (select * from public.chat_threads
             order by unread_admin desc, last_at desc
             limit v_limit) t
  );
end;
$$;

-- 后台：读某个会话（顺带清未读）
create or replace function public.admin_chat_fetch(p_key text, p_thread bigint)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_th public.chat_threads;
begin
  perform public.hub_require_admin(p_key);

  select * into v_th from public.chat_threads where id = p_thread;
  if not found then
    return json_build_object('ok', false, 'error', '没有这个会话');
  end if;

  update public.chat_threads set unread_admin = 0 where id = p_thread;

  return json_build_object(
    'ok', true,
    'thread', json_build_object(
      'id', v_th.id, 'short', left(v_th.visitor_hash, 8),
      'nickname', coalesce(v_th.nickname, ''), 'city', coalesce(v_th.city, ''),
      'status', v_th.status
    ),
    'messages', coalesce((
      select json_agg(json_build_object(
               'id', m.id, 'side', m.side, 'body', m.body, 'at', m.created_at
             ) order by m.id)
        from public.chat_messages m where m.thread_id = p_thread
    ), '[]'::json)
  );
end;
$$;

-- 后台：回复
create or replace function public.admin_chat_reply(p_key text, p_thread bigint, p_body text)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_body text := left(btrim(coalesce(p_body, '')), 500);
  v_id   bigint;
begin
  perform public.hub_require_admin(p_key);
  if length(v_body) < 1 then
    return json_build_object('ok', false, 'error', '写点内容再发');
  end if;
  if not exists (select 1 from public.chat_threads where id = p_thread) then
    return json_build_object('ok', false, 'error', '没有这个会话');
  end if;

  insert into public.chat_messages (thread_id, side, body)
  values (p_thread, 'admin', v_body)
  returning id into v_id;

  update public.chat_threads
     set unread_visitor = unread_visitor + 1, last_at = now()
   where id = p_thread;

  return json_build_object('ok', true, 'id', v_id);
end;
$$;

-- 后台：关掉 / 重开会话
create or replace function public.admin_chat_close(p_key text, p_thread bigint, p_close boolean default true)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.hub_require_admin(p_key);
  update public.chat_threads
     set status = case when coalesce(p_close, true) then 'closed' else 'open' end,
         unread_admin = 0
   where id = p_thread;
  if not found then
    return json_build_object('ok', false, 'error', '没有这个会话');
  end if;
  return json_build_object('ok', true);
end;
$$;

revoke all on function public.chat_fetch(text, bigint) from public;
revoke all on function public.chat_send(text, text, text) from public;
revoke all on function public.admin_chat_list(text, integer) from public;
revoke all on function public.admin_chat_fetch(text, bigint) from public;
revoke all on function public.admin_chat_reply(text, bigint, text) from public;
revoke all on function public.admin_chat_close(text, bigint, boolean) from public;

grant execute on function public.chat_fetch(text, bigint) to anon, authenticated;
grant execute on function public.chat_send(text, text, text) to anon, authenticated;
grant execute on function public.admin_chat_list(text, integer) to anon, authenticated;
grant execute on function public.admin_chat_fetch(text, bigint) to anon, authenticated;
grant execute on function public.admin_chat_reply(text, bigint, text) to anon, authenticated;
grant execute on function public.admin_chat_close(text, bigint, boolean) to anon, authenticated;

-- ============================================================
-- 后台：库里各表的记录数（仪表盘「库里的表」）
-- ============================================================
create or replace function public.admin_tables(p_key text)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.hub_require_admin(p_key);

  return (
    with t(tbl, label, note, cnt) as (
      select 'invite_codes', '邀请码', '池子里的码：明文、状态、剩余次数、队列顺位', count(*) from public.invite_codes
      union all select 'reports', '揭晓记录', '谁在什么时候揭走了哪个码，每日配额也算在这', count(*) from public.reports
      union all select 'publish_log', '发布流水', '全站发布限流用，按小时记', count(*) from public.publish_log
      union all select 'feedback', '反馈', '访客点的「无效 / 已被用 / 信息不对 / 其他」', count(*) from public.feedback
      union all select 'reveal_requests', '发码申请', '人工发码的排队队列，open 的就是待发', count(*) from public.reveal_requests
      union all select 'visitor_meta', '设备档案', '访问 IP、城市、浏览器（完整 IP 只在后台）', count(*) from public.visitor_meta
      union all select 'visitor_blocks', '受限设备', '欠码不还、或手动拉黑的设备', count(*) from public.visitor_blocks
      union all select 'reject_log', '被拒收录', '格式没过的提交，只留 7 天', count(*) from public.reject_log
      union all select 'chat_threads', '客服会话', '一台设备一条会话', count(*) from public.chat_threads
      union all select 'chat_messages', '客服消息', '会话里的每一条消息', count(*) from public.chat_messages
      union all select 'app_settings', '设置', '管理密码、出码方式、水印，只有一行', count(*) from public.app_settings
    )
    select json_agg(json_build_object('name', tbl, 'label', label, 'note', note, 'rows', cnt)
                    order by cnt desc, tbl)
      from t
  );
end;
$$;

-- ============================================================
-- 后台：仪表盘图表用的按天统计（北京时间）
-- ============================================================
create or replace function public.admin_charts(p_key text, p_days integer default 7)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_days integer := least(greatest(coalesce(p_days, 7), 3), 30);
begin
  perform public.hub_require_admin(p_key);

  return (
    with d as (
      select generate_series(public.hub_today() - (v_days - 1), public.hub_today(), interval '1 day')::date as day
    )
    select json_build_object(
      'days', (select json_agg(to_char(day, 'MM-DD') order by day) from d),
      'publish', (select json_agg(coalesce((
                    select count(*) from public.publish_log p
                     where ((p.created_at at time zone 'UTC') + interval '8 hours')::date = d.day), 0) order by d.day) from d),
      'reveal', (select json_agg(coalesce((
                    select count(*) from public.reports r
                     where r.action = 'reveal'
                       and ((r.created_at at time zone 'UTC') + interval '8 hours')::date = d.day), 0) order by d.day) from d),
      'request', (select json_agg(coalesce((
                    select count(*) from public.reveal_requests q
                     where ((q.created_at at time zone 'UTC') + interval '8 hours')::date = d.day), 0) order by d.day) from d),
      'visitor', (select json_agg(coalesce((
                    select count(*) from public.visitor_meta v
                     where ((v.first_seen at time zone 'UTC') + interval '8 hours')::date = d.day), 0) order by d.day) from d),
      'codes', json_build_object(
        'available', (select count(*) from public.invite_codes where status = 'available'),
        'used', (select count(*) from public.invite_codes where status = 'used'),
        'expired', (select count(*) from public.invite_codes where status = 'expired')
      ),
      'chat', json_build_object(
        'threads', (select count(*) from public.chat_threads),
        'unread', (select coalesce(sum(unread_admin), 0) from public.chat_threads)
      )
    )
  );
end;
$$;

revoke all on function public.admin_tables(text) from public;
revoke all on function public.admin_charts(text, integer) from public;
grant execute on function public.admin_tables(text) to anon, authenticated;
grant execute on function public.admin_charts(text, integer) to anon, authenticated;
