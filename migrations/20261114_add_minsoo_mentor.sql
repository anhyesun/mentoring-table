-- Apply to an existing Supabase project to enable mentor table 18.
begin;

do $$
begin
  if exists (
    select 1
      from public.signups
     group by table_no, name_key
    having count(*) > 1
  ) then
    raise exception 'Cannot add signups_one_per_mentor: duplicate mentor signups already exist';
  end if;

  if not exists (
    select 1
      from pg_constraint
     where conrelid = 'public.signups'::regclass
       and conname = 'signups_one_per_mentor'
  ) then
    alter table public.signups
      add constraint signups_one_per_mentor unique (table_no, name_key);
  end if;
end $$;

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

  select taken into v_taken from public.slot_counts
   where table_no = p_table and round = p_round for update;
  if not found then raise exception 'INVALID_SLOT'; end if;
  if v_taken >= 5 then raise exception 'FULL'; end if;

  select s.table_no into v_other from public.signups s
   where s.round = p_round and s.name_key = v_key;
  if found then raise exception 'DUPLICATE:%', v_other; end if;

  select s.round into v_other from public.signups s
   where s.table_no = p_table and s.name_key = v_key;
  if found then raise exception 'SAME_MENTOR:%', v_other; end if;

  begin
    return query
      insert into public.signups (table_no, round, first_name, last_name, name_key)
      values (p_table, p_round, v_first, v_last, v_key)
      returning signups.id, signups.cancel_token;
  exception when unique_violation then
    get stacked diagnostics v_con = constraint_name;
    if v_con = 'signups_one_per_mentor' then raise exception 'SAME_MENTOR'; end if;
    raise exception 'DUPLICATE';
  end;
end $$;

revoke all on function public.sign_up(int, int, text, text) from public;
grant execute on function public.sign_up(int, int, text, text) to anon, authenticated;

commit;

select
  exists (
    select 1 from pg_constraint
     where conrelid = 'public.signups'::regclass
       and conname = 'signups_one_per_mentor'
  ) as same_mentor_constraint_enabled,
  position(
    'p_table between 19 and 20'
    in pg_get_functiondef('public.sign_up(int, int, text, text)'::regprocedure)
  ) > 0 as table_18_enabled,
  position(
    'SAME_MENTOR'
    in pg_get_functiondef('public.sign_up(int, int, text, text)'::regprocedure)
  ) > 0 as same_mentor_guard_enabled;
