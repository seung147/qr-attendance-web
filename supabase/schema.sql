-- =====================================================================
-- 대륜E&S QR 출석 인증 — Supabase 스키마
-- Supabase 대시보드 > SQL Editor 에 전체를 붙여넣고 [Run] 한 번 실행
-- 다시 실행해도 안전합니다(기존 데이터 유지).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- 1. 테이블 ------------------------------------------------------------

-- 관리자(인사팀) 이메일 목록: 여기 등록된 계정만 관리 화면을 씁니다.
create table if not exists public.admins (
  email text primary key
);

-- 직원 명단
create table if not exists public.employees (
  id         uuid primary key default gen_random_uuid(),
  emp_no     text not null unique,          -- 사번
  team       text not null,                 -- 팀이름
  name       text not null,                 -- 이름
  ext        text not null default '',      -- 사내번호
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

-- 교육 회차
create table if not exists public.sessions (
  id             uuid primary key default gen_random_uuid(),
  course         text not null,
  round          text not null,
  edu_date       date not null,
  start_time     text not null,             -- 'HH:MM'
  end_time       text not null,
  place          text not null default '',
  lecturer       text not null default '',
  min_minutes    int  not null default 55,  -- 이수 기준 체류(분)
  target_teams   text[] not null default '{}', -- 비우면 전체
  require_emp_no boolean not null default false, -- 사번 직접 입력으로 본인 확인
  phase          text not null default 'idle' check (phase in ('idle','in','out','closed')),
  created_at     timestamptz not null default now()
);
-- v2: 회차별 대상자를 사번으로 지정 (비우면 target_teams 기준)
alter table public.sessions add column if not exists target_emp_nos text[] not null default '{}';

-- 출석 기록 (인증 당시의 팀·이름을 함께 남겨 명단이 바뀌어도 기록 유지)
create table if not exists public.checkins (
  id          uuid primary key default gen_random_uuid(),
  session_id  uuid not null references public.sessions(id) on delete cascade,
  emp_no      text not null,
  team        text not null,
  name        text not null,
  ext         text not null default '',
  in_at       timestamptz,
  out_at      timestamptz,
  in_device   text,                          -- 기기 식별값(대리 인증 확인용)
  out_device  text,
  in_manual   text,                          -- 관리자 수동등록 사유
  out_manual  text,
  override    text not null default '' check (override in ('','이수','미이수','확인필요')),
  created_at  timestamptz not null default now(),
  unique (session_id, emp_no)
);
create index if not exists checkins_session_idx on public.checkins(session_id);

-- QR 토큰 서명용 비밀값 (API로는 아무도 읽을 수 없음)
create table if not exists public.app_secret (
  id     int primary key default 1 check (id = 1),
  secret text not null
);
insert into public.app_secret(id, secret)
values (1, encode(extensions.gen_random_bytes(32), 'hex'))
on conflict (id) do nothing;

-- 2. 권한(RLS) -------------------------------------------------------

-- 테이블 사용 권한: 로그인한 관리자에게만 (직원(anon)은 아래 인증 함수로만 접근)
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.employees, public.sessions, public.checkins to authenticated;
grant select on public.admins to authenticated;
revoke all on public.employees, public.sessions, public.checkins, public.admins, public.app_secret from anon;
revoke all on public.app_secret from authenticated;

alter table public.admins     enable row level security;
alter table public.employees  enable row level security;
alter table public.sessions   enable row level security;
alter table public.checkins   enable row level security;
alter table public.app_secret enable row level security;   -- 정책 없음 = 접근 불가

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.admins
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;
revoke execute on function public.is_admin() from public, anon;
grant  execute on function public.is_admin() to authenticated;

drop policy if exists "admin self read" on public.admins;
create policy "admin self read" on public.admins
  for select to authenticated using (lower(email) = lower(coalesce(auth.jwt() ->> 'email','')));

drop policy if exists "admin all" on public.employees;
create policy "admin all" on public.employees
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "admin all" on public.sessions;
create policy "admin all" on public.sessions
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "admin all" on public.checkins;
create policy "admin all" on public.checkins
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- 직원(비로그인)은 테이블에 직접 접근하지 못하고, 아래 두 함수로만 인증합니다.

-- 3. QR 토큰: 30초 단위로 바뀌는 서명값, 발급 후 5분(10칸)까지 유효 --------

create or replace function public._qr_token(p_session uuid, p_slot bigint) returns text
language sql stable security definer set search_path = public, extensions as $$
  select substr(encode(extensions.hmac(
    p_session::text || ':' || p_slot::text,
    (select secret from public.app_secret where id = 1),
    'sha256'), 'hex'), 1, 16);
$$;
revoke execute on function public._qr_token(uuid, bigint) from public, anon, authenticated;

-- 토큰이 몇 칸 전 것인지(0~10), 무효면 -1
create or replace function public._token_age(p_session uuid, p_token text) returns int
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  cur bigint := floor(extract(epoch from now()) / 30)::bigint;
  i int;
begin
  if p_token is null or length(p_token) <> 16 then return -1; end if;
  for i in 0..10 loop
    if public._qr_token(p_session, cur - i) = p_token then return i; end if;
  end loop;
  return -1;
end $$;
revoke execute on function public._token_age(uuid, text) from public, anon, authenticated;

-- 관리자 QR 화면용: 현재 토큰과 다음 교체까지 남은 초
create or replace function public.qr_token(p_session uuid) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  ep  double precision := extract(epoch from now());
  cur bigint := floor(ep / 30)::bigint;
begin
  if not public.is_admin() then raise exception 'not admin'; end if;
  return json_build_object('token', public._qr_token(p_session, cur),
                           'next_in', (cur + 1) * 30 - ep);
end $$;
revoke execute on function public.qr_token(uuid) from public, anon;
grant  execute on function public.qr_token(uuid) to authenticated;

-- 4. 직원 인증용 함수 --------------------------------------------------
-- (v2) 사내번호는 화면에 내려보내지 않고, 직원이 직접 입력한 값을 서버에서 대조합니다.

-- QR 스캔 직후: 회차 정보 + 선택용 명단(팀·이름·사번)
create or replace function public.checkin_context(p_session uuid, p_token text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  s   public.sessions;
  age int;
  ep  double precision := extract(epoch from now());
begin
  select * into s from public.sessions where id = p_session;
  if not found then return json_build_object('status', 'not_found'); end if;
  if s.phase not in ('in', 'out') then return json_build_object('status', s.phase); end if;
  age := public._token_age(p_session, p_token);
  if age < 0 then return json_build_object('status', 'expired'); end if;
  return json_build_object(
    'status', 'ok',
    'phase', s.phase,
    'expires_in', floor((floor(ep / 30) - age + 11) * 30 - ep),
    'session', json_build_object(
      'course', s.course, 'round', s.round, 'edu_date', s.edu_date,
      'start_time', s.start_time, 'end_time', s.end_time, 'place', s.place,
      'require_emp_no', s.require_emp_no),
    'roster', coalesce((
      select json_agg(json_build_object(
               'id', e.id, 'team', e.team, 'name', e.name,
               'emp_no', case when s.require_emp_no then null else e.emp_no end)
             order by e.team, e.name)
      from public.employees e where e.active), '[]'::json)
  );
end $$;
grant execute on function public.checkin_context(uuid, text) to anon, authenticated;

-- 인증 버튼: 사내번호(필수)·사번(선택) 대조 후 입실/퇴실 기록
drop function if exists public.checkin_submit(uuid, text, uuid, text, text);
create or replace function public.checkin_submit(
  p_session uuid, p_token text, p_employee uuid, p_device text,
  p_ext text default null, p_emp_no text default null
) returns json
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  s public.sessions;
  e public.employees;
  c public.checkins;
  t timestamptz := now();
  dev text := left(coalesce(p_device, ''), 64);
begin
  select * into s from public.sessions where id = p_session;
  if not found then return json_build_object('status', 'not_found'); end if;
  if s.phase not in ('in', 'out') then return json_build_object('status', s.phase); end if;
  if public._token_age(p_session, p_token) < 0 then return json_build_object('status', 'expired'); end if;

  select * into e from public.employees where id = p_employee and active;
  if not found then return json_build_object('status', 'no_employee'); end if;
  -- 사내번호: 숫자만 비교 (명단에 사내번호가 비어 있는 직원은 확인 생략)
  if regexp_replace(e.ext, '\D', '', 'g') <> ''
     and regexp_replace(coalesce(p_ext, ''), '\D', '', 'g') <> regexp_replace(e.ext, '\D', '', 'g') then
    return json_build_object('status', 'ext_mismatch');
  end if;
  if s.require_emp_no and coalesce(trim(p_emp_no), '') <> e.emp_no then
    return json_build_object('status', 'emp_mismatch');
  end if;

  select * into c from public.checkins where session_id = p_session and emp_no = e.emp_no;

  if s.phase = 'in' then
    if found and c.in_at is not null then
      return json_build_object('status','already','phase','in','at',c.in_at,'name',e.name,'team',e.team);
    end if;
    insert into public.checkins(session_id, emp_no, team, name, ext, in_at, in_device)
    values (p_session, e.emp_no, e.team, e.name, e.ext, t, dev)
    on conflict (session_id, emp_no) do update set in_at = excluded.in_at, in_device = excluded.in_device;
  else
    if found and c.out_at is not null then
      return json_build_object('status','already','phase','out','at',c.out_at,'name',e.name,'team',e.team);
    end if;
    insert into public.checkins(session_id, emp_no, team, name, ext, out_at, out_device)
    values (p_session, e.emp_no, e.team, e.name, e.ext, t, dev)
    on conflict (session_id, emp_no) do update set out_at = excluded.out_at, out_device = excluded.out_device;
  end if;

  return json_build_object('status','ok','phase',s.phase,'at',t,'name',e.name,'team',e.team);
end $$;
revoke execute on function public.checkin_submit(uuid, text, uuid, text, text, text) from public;
grant execute on function public.checkin_submit(uuid, text, uuid, text, text, text) to anon, authenticated;

-- 5. 첫 관리자 등록 (본인 이메일로 바꿔서 실행) ---------------------------
-- insert into public.admins(email) values ('hr@daeryun.co.kr') on conflict do nothing;
