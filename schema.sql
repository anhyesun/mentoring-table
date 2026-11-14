-- 창발 멘토링 데이 2026: Supabase SQL Editor에서 한 번 실행
-- 신청 내역 (이름 포함, 외부 직접 접근 차단)
create table public.signups (
  id            uuid primary key default gen_random_uuid(),
  table_no      smallint not null check (table_no between 1 and 20),
  round         smallint not null check (round in (1, 2)),
  first_name    text not null check (char_length(first_name) between 1 and 60),
  last_name     text not null check (char_length(last_name) between 1 and 60),
  name_key      text not null,
  cancel_token  uuid not null default gen_random_uuid(),
  created_at    timestamptz not null default now(),
  unique (round, name_key)          -- 같은 라운드 같은 이름 금지 (최종 안전장치)
);

-- 라운드별 신청 수 (공개, 실시간 구독용)
create table public.slot_counts (
  table_no  smallint not null,
  round     smallint not null,
  taken     smallint not null default 0 check (taken between 0 and 5),
  primary key (table_no, round)
);

insert into public.slot_counts (table_no, round)
select t, r from generate_series(1, 20) t, generate_series(1, 2) r;

-- 권한: signups는 함수로만 접근, slot_counts는 읽기만 공개
alter table public.signups enable row level security;
alter table public.slot_counts enable row level security;
create policy "public read counts" on public.slot_counts for select using (true);
revoke all on public.signups from anon, authenticated;
revoke insert, update, delete on public.slot_counts from anon, authenticated;
grant select on public.slot_counts to anon, authenticated;

-- 신청 수 자동 동기화
create or replace function public.sync_slot_counts() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update slot_counts set taken = taken + 1 where table_no = new.table_no and round = new.round;
  elsif tg_op = 'DELETE' then
    update slot_counts set taken = taken - 1 where table_no = old.table_no and round = old.round;
  end if;
  return null;
end $$;

create trigger signups_sync after insert or delete on public.signups
for each row execute function public.sync_slot_counts();

-- 신청: 정원, 중복을 한 번에 확인 (동시 신청 안전)
create or replace function public.sign_up(p_table int, p_round int, p_first text, p_last text)
returns table (signup_id uuid, cancel_token uuid)
language plpgsql security definer set search_path = public as $$
declare
  v_first text := regexp_replace(trim(coalesce(p_first, '')), '\s+', ' ', 'g');
  v_last  text := regexp_replace(trim(coalesce(p_last, '')), '\s+', ' ', 'g');
  v_key   text;
  v_taken int;
  v_other int;
begin
  if v_first = '' or v_last = '' then raise exception 'NAME_REQUIRED'; end if;
  if p_table between 18 and 20 then raise exception 'NO_MENTOR'; end if;  -- 멘토 확정 시 이 줄 수정
  v_key := lower(v_first) || ' ' || lower(v_last);

  -- 이 테이블/라운드 행을 잠가서 동시에 들어온 신청을 한 줄로 세움
  select taken into v_taken from slot_counts
   where table_no = p_table and round = p_round for update;
  if not found then raise exception 'INVALID_SLOT'; end if;
  if v_taken >= 5 then raise exception 'FULL'; end if;

  select s.table_no into v_other from signups s where s.round = p_round and s.name_key = v_key;
  if found then raise exception 'DUPLICATE:%', v_other; end if;

  begin
    return query
      insert into signups (table_no, round, first_name, last_name, name_key)
      values (p_table, p_round, v_first, v_last, v_key)
      returning signups.id, signups.cancel_token;
  exception when unique_violation then
    raise exception 'DUPLICATE';
  end;
end $$;

-- 취소: 신청할 때 받은 토큰이 있어야만 삭제
create or replace function public.cancel_signup(p_id uuid, p_token uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
declare v_rows int;
begin
  delete from signups where id = p_id and cancel_token = p_token;
  get diagnostics v_rows = row_count;
  return v_rows = 1;
end $$;

revoke all on function public.sign_up(int, int, text, text) from public;
revoke all on function public.cancel_signup(uuid, uuid) from public;
grant execute on function public.sign_up(int, int, text, text) to anon, authenticated;
grant execute on function public.cancel_signup(uuid, uuid) to anon, authenticated;

-- 실시간: 자리 수 변경을 모든 기기에 전송
alter publication supabase_realtime add table public.slot_counts;
