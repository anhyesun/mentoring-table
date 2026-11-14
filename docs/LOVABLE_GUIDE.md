# 창발 멘토링 데이 2026 — Lovable 이전 가이드

지금 HTML은 신청 내용을 각 브라우저의 `localStorage`에만 저장해요. 이 가이드는 같은 화면을 Lovable로 옮기고, Supabase에 저장해서 **여러 기기에서 같은 남은 자리 수를 실시간으로** 보도록 연결하는 방법을 정리한 거예요.

## 1. 파일 구성

| 파일 | 내용 |
|---|---|
| `changbal-mentoring-tables.html` | 현재 완성본. 디자인, 동작, 문구의 기준(레퍼런스) |
| `assets/mentors.json` | 테이블 20개, 멘토 정보, 라운드, 좌석 규칙 |
| `assets/photos/*.jpg` | 멘토 프로필 사진 14장 (240×240). 사진이 없는 멘토는 기본 아바타 사용 |
| `assets/logos/*-on-light.png` / `*-on-dark.png` | 회사 로고. 밝은 배경용과 어두운 배경용 두 벌 |

HTML 안에는 사진과 로고가 base64로 들어 있어서 파일이 커요. Lovable에서는 `assets/` 폴더의 이미지를 `public/`에 넣고 경로로 쓰는 게 좋아요.

## 2. 현재 화면과 동작 요약 (그대로 유지할 것)

- **배치도**: 4열 × 5줄 = 테이블 20개. 왼쪽 위부터 오른쪽으로 번호(1–4, 5–8 …). 왼쪽 벽에 출입구 2개와 화이트보드, 포디엄은 3번째 줄 왼쪽.
- **테이블**: 사각형 안에 번호(01–20)와 회사 로고. 18–20번은 멘토 미정이라 점선 테두리.
- **좌석 포도알**: 테이블당 6개(위 2, 오른쪽 2, 아래 2). **오른쪽 위 자리가 멘토 자리**(진한 남색). 나머지 5자리는 신청 순서대로 위 2 → 오른쪽 아래 → 아래 2 순서로 보라색으로 채움.
- **라운드 토글**: 배치도 위 Round 1 / Round 2 버튼. 선택한 라운드 기준으로 좌석을 칠함.
  - Round 1: 3:30 – 4:30 PM
  - Round 2: 4:40 – 5:40 PM
- **상세 패널**: 테이블을 누르면 데스크톱은 오른쪽 패널, 모바일(≤820px)은 바텀시트.
  - 순서: 테이블 번호 → 사진(없으면 아바타) → 이름 → 로고 → 회사명(로고만으로 소속이 안 드러날 때만: Amazon AWS, Google DeepMind, Microsoft Red Team) → 직함 → LinkedIn 버튼 → 멘토링 신청.
  - 모바일 바텀시트는 처음에 LinkedIn 버튼까지만 보이는 높이로 열리고, 시트 안에서 스크롤하면 화면 높이까지 커짐.
- **신청 폼**: First Name, Last Name (둘 다 필수). 라운드마다 정원 5명.
  - 같은 이름(대소문자, 앞뒤 공백 무시)은 **같은 라운드에 한 번만** 신청 가능. 다른 라운드는 가능.
  - 마감되면 버튼이 "마감"으로 바뀜.
- **멘토 찾기**: 이름, 회사, 분야로 검색. 맞지 않는 테이블은 흐리게. 목록에 라운드별 남은 자리 표시.
- **링크 공유**: 주소 끝 `#table-14` 같은 해시로 해당 테이블이 열린 상태로 진입.
- **테마**: 라이트/다크 모드 자동 대응. 메인 색 `#5B4FD6`, 글자 `#22224A`, 배경 `#F5F5FA`, 글꼴 IBM Plex Sans KR.

## 3. 여러 기기에서 쓰기 위한 설계

브라우저 저장소 대신 Supabase를 써요. 핵심 원칙은 세 가지예요.

1. **정원과 중복 확인은 서버에서 한다.** 브라우저에서 "자리 수 확인 → 저장"을 따로 하면, 두 사람이 동시에 마지막 자리를 누를 때 6명이 들어갈 수 있어요. 그래서 확인과 저장을 하나의 데이터베이스 함수(`sign_up`) 안에서 행 잠금과 함께 처리해요.
2. **전체 이름은 공개하지 않고, 신청자의 first name은 공개한다.** `signups` 테이블은 외부에서 직접 읽지 못하게 막지만, `slot_counts.first_names`를 통해 테이블별 신청자의 first name은 누구나 볼 수 있어요. 이름 공개가 적절하지 않은 행사라면 HTML의 신청자 표시와 이 공개 필드를 제거하세요.
3. **취소는 본인만 한다.** 신청하면 `cancel_token`을 돌려주고, 그 기기의 `localStorage`에 보관해요. 취소할 때 이 토큰이 있어야만 지워져요. 운영진은 Supabase 대시보드에서 직접 지울 수 있어요.

### 3-1. Supabase SQL (SQL Editor에 그대로 실행)

```sql
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
```

이미 기존 Supabase 스키마를 운영 중이라면 전체 SQL을 다시 실행하지 말고, 저장소의 [schema.sql](../schema.sql)에서 `기존 프로젝트에도 적용할 수 있도록 컬럼이 없을 때만 추가` 주석부터 `signups_sync` 트리거 생성까지의 블록을 실행하세요. 이 블록은 공개 first name 필드를 추가하고 기존 신청 데이터를 채웁니다.

### 3-2. 클라이언트 연동 (supabase-js 예시)

```ts
// 1) 처음 로드: 라운드별 자리 수와 공개된 first name
const { data: counts } = await supabase.from("slot_counts").select("table_no, round, taken, first_names");
// counts → Map key `${table_no}-${round}` → { taken, first_names }

// 2) 실시간 구독: 누가 신청/취소하면 바로 반영 (페이지에서 한 번만 구독)
const channel = supabase
  .channel("slot-counts")
  .on("postgres_changes", { event: "UPDATE", schema: "public", table: "slot_counts" },
      (payload) => updateCount(payload.new.table_no, payload.new.round, payload.new.taken, payload.new.first_names))
  .subscribe();

// 3) 신청
const { data, error } = await supabase.rpc("sign_up", {
  p_table: tableNo, p_round: round, p_first: first, p_last: last,
});
if (error) showError(error.message);
else saveMySignup({ id: data[0].signup_id, token: data[0].cancel_token, tableNo, round, name: `${first} ${last}` });

// 4) 취소 (이 기기에서 신청한 것만)
await supabase.rpc("cancel_signup", { p_id: mine.id, p_token: mine.token });
```

에러 메시지는 화면에서 이렇게 바꿔 보여 주세요.

| 서버 메시지 | 화면 문구 |
|---|---|
| `NAME_REQUIRED` | First Name과 Last Name을 모두 입력해 주세요. |
| `FULL` | 이 라운드는 이미 마감됐어요. |
| `DUPLICATE:7` | 이미 Round {n}에 07번 테이블로 신청돼 있어요. |
| `DUPLICATE` (번호 없음) | 이미 이 라운드에 신청돼 있어요. |
| `NO_MENTOR` / `INVALID_SLOT` | 이 테이블은 아직 신청을 받지 않아요. |
| 네트워크 오류 | 연결이 불안정해요. 잠시 후 다시 시도해 주세요. |

"내 신청"(`id`, `cancel_token`, 테이블, 라운드, 이름)은 기기의 `localStorage`에 배열로 보관해서, 패널에 "내 신청: Jisoo Kim (취소)"처럼 보여 주면 돼요.

## 4. Lovable 작업 순서

1. Lovable에서 새 프로젝트를 만들고 Supabase를 연결해요 (Lovable의 Supabase 연동 또는 Lovable Cloud).
2. Supabase SQL Editor에서 3-1의 SQL을 실행해요.
3. `assets/` 폴더의 이미지와 `mentors.json`을 프로젝트에 올려요 (`public/assets/...`).
4. `changbal-mentoring-tables.html`을 첨부하고 아래 프롬프트로 시작해요.
5. 두 기기(또는 브라우저 창 두 개)로 열어서 한쪽에서 신청하면 다른 쪽 좌석이 바로 채워지는지 확인해요.
6. 동시 신청 테스트: 남은 자리가 1개인 테이블에 두 창에서 거의 동시에 신청해서, 한 명만 들어가고 다른 쪽에 "마감" 메시지가 뜨는지 확인해요.

### 첫 프롬프트 예시

```
첨부한 changbal-mentoring-tables.html을 React + TypeScript로 그대로 옮겨줘.
디자인, 문구, 레이아웃, 모바일 바텀시트 동작, 라이트/다크 모드를 원본과 똑같이 맞춰줘.

데이터:
- 멘토, 라운드, 좌석 규칙은 public/assets/mentors.json에서 읽어.
- 사진은 public/assets/photos, 로고는 public/assets/logos의 -on-light / -on-dark 두 벌을
  테마와 선택 상태에 맞게 바꿔 써. (선택된 보라색 테이블 위에서는 라이트 모드에서도 -on-dark)
- 사진이 없는 멘토는 원본의 기본 아바타 SVG를 써.

저장:
- localStorage 대신 Supabase를 써. 테이블과 함수는 이미 만들어져 있어:
  slot_counts(table_no, round, taken, first_names) 공개 읽기 + 실시간. first_names로 신청자의 first name을 공개해,
  rpc sign_up(p_table, p_round, p_first, p_last) → {signup_id, cancel_token},
  rpc cancel_signup(p_id, p_token) → boolean.
- 좌석 수는 slot_counts를 처음 한 번 읽고 realtime으로 갱신해.
- 공개된 신청자 first name 목록은 테이블 상세에 표시해. 전체 이름은 공개하지 마. 이 기기에서 신청한 것은
  localStorage에 {id, token, tableNo, round, name}으로 저장해서 "내 신청"으로 보여 주고 취소 버튼을 달아줘.
- 서버 에러 메시지(NAME_REQUIRED, FULL, DUPLICATE:n, NO_MENTOR)는 한국어 안내 문구로 바꿔서 보여줘.
- 신청 버튼은 요청 중에 비활성화해서 두 번 눌리지 않게 해줘.
```

## 5. 운영 팁

- **신청자 명단 보기**: Supabase 대시보드 → Table Editor → `signups`에서 보고 CSV로 내려받을 수 있어요. 테이블별로 정렬하려면 `table_no`, `round` 순으로 정렬하세요.
- **멘토 확정(18–20번)**: `mentors.json`에 정보를 넣고, `sign_up` 함수의 `NO_MENTOR` 줄 범위를 고쳐요.
- **정원 변경**: `slot_counts`의 `check (taken between 0 and 5)`와 `sign_up`의 `>= 5`, 그리고 `mentors.json`의 `seatsPerRound`를 함께 바꿔요.
- **행사 전 초기화**: 테스트 신청을 지울 때는 `delete from signups;` 한 줄이면 `slot_counts`도 트리거로 같이 0이 돼요.
- **장난 신청 대비**: 링크가 공개되면 아무 이름으로나 신청할 수 있어요. 필요하면 행사 코드 입력칸을 추가하고 `sign_up`에서 코드를 확인하거나, 참가자 명단(사전 등록자)과 이름을 대조하는 방식을 고려하세요.
- **개인정보**: 신청자의 first name은 공개 `slot_counts`에서 누구나 읽을 수 있어요. first name도 공개하면 안 되는 행사라면 공개 API에서 이름 필드를 제외하고 화면 표시 기능도 꺼야 해요.
