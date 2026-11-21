-- =====================================================================
-- v2 업데이트 (이미 schema.sql을 실행한 프로젝트용)
-- SQL Editor에 전체를 붙여넣고 [Run] 한 번. 기존 데이터는 그대로 유지됩니다.
--  · 회차별 대상자 사번 지정 칸 추가
--  · 직원 인증 시 사내번호 직접 입력·대조
-- =====================================================================

alter table public.sessions add column if not exists target_emp_nos text[] not null default '{}';

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

