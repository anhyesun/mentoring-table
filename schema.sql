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
  constraint signups_round_name_key_key unique (round, name_key),
  constraint signups_one_per_mentor unique (table_no, name_key)
);

-- 기존 데이터에 같은 멘토 중복이 없는 경우에만 제약을 추가
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.signups'::regclass
       and conname = 'signups_one_per_mentor'
  ) then
    if exists (
      select 1 from public.signups
       group by table_no, name_key
      having count(*) > 1
    ) then
      raise exception 'Cannot add signups_one_per_mentor: duplicate mentor signups already exist';
    end if;
    alter table public.signups
      add constraint signups_one_per_mentor unique (table_no, name_key);
  end if;
end $$;

-- 라운드별 신청 수 (공개, 실시간 구독용)
create table public.slot_counts (
  table_no    smallint not null,
  round       smallint not null,
  taken       smallint not null default 0 check (taken between 0 and 5),
  first_names text[] not null default '{}'::text[],
  primary key (table_no, round)
);

-- 기존 프로젝트에도 적용할 수 있도록 컬럼이 없을 때만 추가
alter table public.slot_counts
  add column if not exists first_names text[] not null default '{}'::text[];

comment on column public.slot_counts.first_names is
  'Public first names shown beside table availability; readable by anon clients.';

insert into public.slot_counts (table_no, round)
select t, r from generate_series(1, 20) t, generate_series(1, 2) r
on conflict (table_no, round) do nothing;

-- 기존 신청 데이터로 공개 first name 목록과 신청 수를 맞춤
update public.slot_counts c
set taken = (
      select count(*)::smallint
      from public.signups s
      where s.table_no = c.table_no and s.round = c.round
    ),
    first_names = coalesce((
      select array_agg(s.first_name order by s.created_at, s.id)
      from public.signups s
      where s.table_no = c.table_no and s.round = c.round
    ), '{}'::text[]);

-- 권한: signups는 함수로만 접근, slot_counts는 읽기만 공개
alter table public.signups enable row level security;
alter table public.slot_counts enable row level security;
drop policy if exists "public read counts" on public.slot_counts;
create policy "public read counts" on public.slot_counts for select using (true);
revoke all on public.signups from anon, authenticated;
revoke insert, update, delete on public.slot_counts from anon, authenticated;
grant select on public.slot_counts to anon, authenticated;

-- 신청 수 자동 동기화
create or replace function public.sync_slot_counts() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_table smallint;
  v_round smallint;
begin
  if tg_op = 'INSERT' then
    v_table := new.table_no;
    v_round := new.round;
  elsif tg_op = 'DELETE' then
    v_table := old.table_no;
    v_round := old.round;
  end if;

  update public.slot_counts c
  set taken = snapshot.taken,
      first_names = snapshot.first_names
  from (
    select count(*)::smallint as taken,
           coalesce(array_agg(s.first_name order by s.created_at, s.id), '{}'::text[]) as first_names
    from public.signups s
    where s.table_no = v_table and s.round = v_round
  ) snapshot
  where c.table_no = v_table and c.round = v_round;

  return null;
end $$;

drop trigger if exists signups_sync on public.signups;
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
  v_con   text;
begin
  if v_first = '' or v_last = '' then raise exception 'NAME_REQUIRED'; end if;
  if p_table between 19 and 20 then raise exception 'NO_MENTOR'; end if;
  v_key := lower(v_first) || ' ' || lower(v_last);

  -- 이 테이블/라운드 행을 잠가서 동시에 들어온 신청을 한 줄로 세움
  select taken into v_taken from slot_counts
   where table_no = p_table and round = p_round for update;
  if not found then raise exception 'INVALID_SLOT'; end if;
  if v_taken >= 5 then raise exception 'FULL'; end if;

  select s.table_no into v_other from signups s where s.round = p_round and s.name_key = v_key;
  if found then raise exception 'DUPLICATE:%', v_other; end if;

  select s.round into v_other from signups s where s.table_no = p_table and s.name_key = v_key;
  if found then raise exception 'SAME_MENTOR:%', v_other; end if;

  begin
    return query
      insert into signups (table_no, round, first_name, last_name, name_key)
      values (p_table, p_round, v_first, v_last, v_key)
      returning signups.id, signups.cancel_token;
  exception when unique_violation then
    get stacked diagnostics v_con = constraint_name;
    if v_con = 'signups_one_per_mentor' then raise exception 'SAME_MENTOR'; end if;
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
