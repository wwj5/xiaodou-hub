-- 小豆邀请码互助站 · Supabase 数据库初始化
-- 在 Supabase Dashboard → SQL Editor 里整段粘贴执行一次即可。
-- 设计参考 muse-invite-hub：所有写入都走 SECURITY DEFINER RPC，前端只持有 anon key。
-- 只依赖 PostgreSQL 内置的 sha256()，不需要 pgcrypto。

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
  action       text not null check (action in ('claim', 'used')),
  visitor_hash text not null,
  created_at   timestamptz not null default now()
);

create unique index if not exists ux_reports
  on public.reports (code_id, visitor_hash, action);
create index if not exists ix_reports_visitor
  on public.reports (visitor_hash, action);

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

create or replace function public.hub_stats()
returns json
language sql
security definer
set search_path = public, extensions, pg_temp
as $$
  select json_build_object(
    'issued',         (select count(*) from public.invite_codes),
    'available',      (select count(*) from public.invite_codes where status = 'available'),
    'used',           (select count(*) from public.invite_codes where status <> 'available'),
    'availableSpots', (select coalesce(sum(remaining_spots), 0) from public.invite_codes where status = 'available')
  );
$$;

create or replace function public.hub_card(p_row public.invite_codes, p_visitor text)
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
    'mine',           (p_row.creator_hash = p_visitor)
  );
$$;

create or replace function public.hub_require_admin(p_key text)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
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

-- 通用管理密钥由你自己执行一次，例如：
-- update public.app_settings
--    set admin_token_hash = encode(sha256(convert_to('你设置的一长串密钥', 'UTF8')), 'hex'), updated_at = now()
--  where id = true;
-- 若表里还没有行，先执行：
-- insert into public.app_settings (id, admin_token_hash)
-- values (true, encode(sha256(convert_to('你设置的一长串密钥', 'UTF8')), 'hex'));

-- ---------------------------------------------------------------- RPC：读

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
set search_path = public, extensions, pg_temp
as $$
declare
  v_status  text := coalesce(nullif(trim(p_status), ''), 'available');
  v_query   text := upper(regexp_replace(coalesce(p_query, ''), '[^A-Za-z0-9]', '', 'g'));
  v_limit   integer := least(greatest(coalesce(p_limit, 500), 1), 500);
  v_offset  integer := greatest(coalesce(p_offset, 0), 0);
  v_visitor text := public.hub_hash(p_token);
  v_cards   json;
begin
  select coalesce(json_agg(t.card), '[]'::json)
    into v_cards
    from (
      select public.hub_card(c, v_visitor) as card
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
    'stats', public.hub_stats()
  );
end;
$$;

create or replace function public.codes_of_visitor(
  p_token text default ''
)
returns json
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_visitor text := public.hub_hash(p_token);
begin
  return json_build_object(
    'ok', true,
    'quotaRemaining', greatest(0, 2 - (select count(*) from public.reports
                                        where visitor_hash = v_visitor and action = 'claim')),
    'myCodes', coalesce((
      select json_agg(public.hub_card(c, v_visitor) order by c.queue_rank)
        from public.invite_codes c
       where c.creator_hash = v_visitor and c.status = 'available'
    ), '[]'::json)
  );
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
set search_path = public, extensions, pg_temp
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
    'card', public.hub_card(v_row, v_visitor),
    'stats', public.hub_stats()
  );
end;
$$;

-- ---------------------------------------------------------------- RPC：领取（剩余次数 -1）

create or replace function public.claim_code(
  p_id    uuid,
  p_token text default ''
)
returns json
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_visitor  text := public.hub_hash(p_token);
  v_row      public.invite_codes;
  v_counted  integer;
  v_hourly   integer;
  v_remaining integer;
begin
  select * into v_row from public.invite_codes where id = p_id for update;
  if not found then
    raise exception '这个邀请码不存在了' using errcode = 'P0001';
  end if;
  if v_row.status <> 'available' or v_row.remaining_spots <= 0 then
    raise exception '这个邀请码已经用完了' using errcode = 'P0001';
  end if;

  if exists (select 1 from public.reports
              where code_id = p_id and visitor_hash = v_visitor and action = 'claim') then
    raise exception '你已经领取过这个码了' using errcode = 'P0001';
  end if;

  select count(*) into v_counted
    from public.reports where visitor_hash = v_visitor and action = 'claim';
  if v_counted >= 2 then
    raise exception '每人最多领取 2 个邀请码，你已经用完了' using errcode = 'P0001';
  end if;

  select count(*) into v_hourly
    from public.reports
   where visitor_hash = v_visitor and created_at >= now() - interval '1 hour';
  if v_hourly >= 60 then
    raise exception '操作太频繁，先歇一会儿' using errcode = 'P0001';
  end if;

  v_remaining := v_row.remaining_spots - 1;

  update public.invite_codes
     set remaining_spots = v_remaining,
         claimed_count   = claimed_count + 1,
         status          = case when v_remaining <= 0 then 'used' else 'available' end,
         updated_at      = now()
   where id = p_id
  returning * into v_row;

  insert into public.reports (code_id, action, visitor_hash) values (p_id, 'claim', v_visitor);

  return json_build_object(
    'ok', true,
    'code', v_row.code,
    'card', public.hub_card(v_row, v_visitor),
    'stats', public.hub_stats(),
    'quotaRemaining', greatest(0, 2 - (v_counted + 1))
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
set search_path = public, extensions, pg_temp
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

-- ---------------------------------------------------------------- RPC：管理

create or replace function public.admin_verify(p_key text)
returns json
language plpgsql
security definer
set search_path = public, extensions, pg_temp
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
set search_path = public, extensions, pg_temp
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
  return json_build_object('ok', true, 'card', public.hub_card(v_row, null));
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
set search_path = public, extensions, pg_temp
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
  v_status := coalesce(nullif(p_status, ''), v_row.status);

  if v_remain < 0 or v_remain > 30 then
    raise exception '剩余次数只能是 0–30' using errcode = 'P0001';
  end if;
  if v_status not in ('available', 'used', 'expired') then
    raise exception '状态不合法' using errcode = 'P0001';
  end if;
  if v_remain = 0 and v_status = 'available' then
    v_status := 'used';
  elsif v_remain > 0 and v_status <> 'available' then
    v_status := 'available';
  end if;

  if p_position is not null then
    select count(*) into v_total from public.invite_codes;
    v_pos := least(greatest(p_position, 1), v_total);
    perform pg_advisory_xact_lock(778899);

    -- 目标码插到 v_pos，原 v_pos 及之后的码顺延一位，最后整体重编号为 1..N
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

  return json_build_object('ok', true, 'card', public.hub_card(v_row, null), 'stats', public.hub_stats());
end;
$$;

create or replace function public.admin_reseed(p_key text)
returns json
language plpgsql
security definer
set search_path = public, extensions, pg_temp
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

-- ---------------------------------------------------------------- 函数授权

revoke all on function public.hub_stats() from public;
revoke all on function public.list_codes(text, text, integer, integer, text) from public;
revoke all on function public.codes_of_visitor(text) from public;
revoke all on function public.publish_code(text, integer, text) from public;
revoke all on function public.claim_code(uuid, text) from public;
revoke all on function public.submit_feedback(uuid, text, text, text) from public;
revoke all on function public.admin_verify(text) from public;
revoke all on function public.admin_find(text, text) from public;
revoke all on function public.admin_update(uuid, text, integer, integer, text) from public;
revoke all on function public.admin_reseed(text) from public;

grant execute on function public.hub_stats() to anon, authenticated;
grant execute on function public.list_codes(text, text, integer, integer, text) to anon, authenticated;
grant execute on function public.codes_of_visitor(text) to anon, authenticated;
grant execute on function public.publish_code(text, integer, text) to anon, authenticated;
grant execute on function public.claim_code(uuid, text) to anon, authenticated;
grant execute on function public.submit_feedback(uuid, text, text, text) to anon, authenticated;
grant execute on function public.admin_verify(text) to anon, authenticated;
grant execute on function public.admin_find(text, text) to anon, authenticated;
grant execute on function public.admin_update(uuid, text, integer, integer, text) to anon, authenticated;
grant execute on function public.admin_reseed(text) to anon, authenticated;

-- hub_hash / hub_card / hub_require_admin 是内部函数，不授权给 anon。
