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

-- ---------------------------------------------------------------- 权限：表一律不可直连

alter table public.invite_codes  enable row level security;
alter table public.reports       enable row level security;
alter table public.publish_log   enable row level security;
alter table public.feedback      enable row level security;
alter table public.app_settings  enable row level security;
alter table public.visitor_blocks enable row level security;
alter table public.reject_log    enable row level security;

revoke all on public.invite_codes  from anon, authenticated;
revoke all on public.reports       from anon, authenticated;
revoke all on public.publish_log   from anon, authenticated;
revoke all on public.feedback      from anon, authenticated;
revoke all on public.app_settings  from anon, authenticated;
revoke all on public.visitor_blocks from anon, authenticated;
revoke all on public.reject_log    from anon, authenticated;

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
    'graceMinutes',   public.hub_grace_minutes()
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
    'createdAt',      p_row.created_at
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
      'graceMinutes', public.hub_grace_minutes()
    )
  );
end;
$$;

-- 搜索不会泄露：搜的是 code_norm，但返回的还是遮罩卡；命中即为"有这么个码"。

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
  v_hint    text := '';
begin
  -- 提交失败一律不算回填：如果这台设备正被限制，提示里说清楚"限制还没解除"
  v_blocked := exists (select 1 from public.visitor_blocks b where b.visitor_hash = v_visitor);
  if v_blocked then
    v_hint := '（这次不算回填，限制还没解除，得重新放一个有效的邀请码）';
  end if;

  -- ---- 格式校验：专收小豆 6 位「字母+数字」码，乱七八糟的一律不收（拒收都进日志）----
  if length(v_norm) <> 6 then
    return public.hub_reject(v_norm, v_visitor,
      '邀请码必须是 6 位，你填的是 ' || length(v_norm) || ' 位', v_hint);
  end if;
  if v_norm !~ '[A-Z]' or v_norm !~ '[0-9]' then
    return public.hub_reject(v_norm, v_visitor,
      '邀请码必须字母和数字都有；纯字母、纯数字的码本站不收', v_hint);
  end if;
  if v_norm ~ '[A-Z]{3}' then
    return public.hub_reject(v_norm, v_visitor,
      '邀请码里不能有 3 个字母连在一起（像乱填的），本站不收', v_hint);
  end if;
  if v_norm ~ '[0-9]{3}' then
    return public.hub_reject(v_norm, v_visitor,
      '邀请码里不能有 3 个数字连在一起（像乱填的），本站不收', v_hint);
  end if;
  if v_norm = any (array['OPENAI','CLOUD','GOOGLE','GITHUB','DOUBAO','PYTHON','MOBILE','SERVER','WINDOW','SYSTEM','PUBLIC','MASTER','SECRET']) then
    return public.hub_reject(v_norm, v_visitor, '这看着是英文单词，不是邀请码，本站不收', v_hint);
  end if;
  if v_norm ~ '(91|78|13|27)' then
    return public.hub_reject(v_norm, v_visitor,
      '邀请码里带了不合适的数字（91 / 78 / 13 / 27），本站不收', v_hint);
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
      select r.visitor_hash as vh, count(*) as taken, max(r.created_at) as last_rev
        from public.reports r
        join public.invite_codes c on c.id = r.code_id
       where r.action = 'reveal' and c.status <> 'expired'
       group by 1
    ),
    pb as (
      select c.creator_hash as vh, count(*) as returned, max(c.created_at) as last_pub
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
  return json_build_object('graceMinutes', public.hub_grace_minutes());
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
revoke all on function public.admin_rejects(text, integer) from public;
revoke all on function public.admin_clear_rejects(text) from public;
revoke all on function public.hub_reject(text, text, text, text) from public;

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
grant execute on function public.admin_rejects(text, integer) to anon, authenticated;
grant execute on function public.admin_clear_rejects(text) to anon, authenticated;



