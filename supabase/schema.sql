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
  updated_at       timestamptz not null default now()
);

-- ---------------------------------------------------------------- 权限：表一律不可直连

alter table public.invite_codes  enable row level security;
alter table public.reports       enable row level security;
alter table public.publish_log   enable row level security;
alter table public.feedback      enable row level security;
alter table public.app_settings  enable row level security;

revoke all on public.invite_codes  from anon, authenticated;
revoke all on public.reports       from anon, authenticated;
revoke all on public.publish_log   from anon, authenticated;
revoke all on public.feedback      from anon, authenticated;
revoke all on public.app_settings  from anon, authenticated;

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
    'availableSpots', (select coalesce(sum(remaining_spots), 0) from public.invite_codes where status = 'available')
  );
$$;

-- 对外卡片：不带明文邀请码，只给遮罩长度和状态
create or replace function public.hub_card_public(p_row public.invite_codes)
returns json
language sql
immutable
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
    'createdAt',      p_row.created_at
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
    raise exception '需要管理密钥' using errcode = 'P0001';
  end if;
  select admin_token_hash into v_hash from public.app_settings where id = true;
  if v_hash is null or v_hash <> encode(sha256(convert_to(trim(p_key), 'UTF8')), 'hex') then
    raise exception '管理密钥不对' using errcode = 'P0001';
  end if;
end;
$$;

-- 通用管理密钥由你自己执行一次（把字符串换掉）：
-- insert into public.app_settings (id, admin_token_hash)
-- values (true, encode(sha256(convert_to('你设置的一长串密钥', 'UTF8')), 'hex'))
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
       order by c.queue_rank asc, c.created_at asc
       limit v_limit offset v_offset
    ) t;

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
    )
  );
end;
$$;

-- 搜索不会泄露：搜的是 code_norm，但返回的还是遮罩卡；命中即为"有这么个码"。

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
begin
  if length(v_norm) < 4 or length(v_norm) > 32 then
    raise exception '邀请码长度需为 4–32 位字母或数字' using errcode = 'P0001';
  end if;
  if v_spots < 1 or v_spots > 30 then
    raise exception '剩余次数必须是 1–30 的整数' using errcode = 'P0001';
  end if;

  select count(*) into v_mine
    from public.invite_codes
   where creator_hash = v_visitor and status = 'available';
  if v_mine >= 1 then
    raise exception '同一个人最多保留 1 个可用邀请码' using errcode = 'P0001';
  end if;

  select count(*) into v_recent
    from public.publish_log
   where created_at >= now() - interval '10 minutes';
  if v_recent >= 30 then
    raise exception '全站发布太频繁，请过几分钟再试' using errcode = 'P0001';
  end if;

  if exists (select 1 from public.invite_codes where code_norm = v_norm) then
    raise exception '该邀请码已经在池里了' using errcode = 'P0001';
  end if;

  select coalesce(max(queue_rank), 0) + 1 into v_rank from public.invite_codes;

  insert into public.invite_codes
    (code, code_norm, status, total_spots, remaining_spots, claimed_count,
     queue_rank, creator_hash)
  values
    (v_norm, v_norm, 'available', v_spots, v_spots, 0, v_rank, v_visitor)
  returning * into v_row;

  insert into public.publish_log (visitor_hash, code_id) values (v_visitor, v_row.id);

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
  select count(*) into v_total_n
    from public.reports
   where visitor_hash = v_visitor and action = 'reveal';
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

  return json_build_object('ok', true);
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
revoke all on function public.admin_resolve_report(bigint, text, boolean) from public;
revoke all on function public.admin_set_key(text, text) from public;

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
grant execute on function public.admin_resolve_report(bigint, text, boolean) to anon, authenticated;
grant execute on function public.admin_set_key(text, text) to anon, authenticated;
