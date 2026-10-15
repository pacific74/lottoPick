-- =====================================================
-- 로또픽 (lottoPick) - Supabase 스키마
-- 기존 stockeye 테이블(public)과 분리하기 위해 lotto 스키마 사용
-- Supabase 대시보드 > SQL Editor 에 붙여넣고 실행
-- =====================================================

create schema if not exists lotto;

-- -----------------------------------------------------
-- 1. 당첨번호 테이블
-- -----------------------------------------------------
create table if not exists lotto.draws (
  round       int primary key,                                   -- 회차
  draw_date   date not null,                                     -- 추첨일
  n1          smallint not null check (n1 between 1 and 45),     -- 번호1
  n2          smallint not null check (n2 between 1 and 45),     -- 번호2
  n3          smallint not null check (n3 between 1 and 45),     -- 번호3
  n4          smallint not null check (n4 between 1 and 45),     -- 번호4
  n5          smallint not null check (n5 between 1 and 45),     -- 번호5
  n6          smallint not null check (n6 between 1 and 45),     -- 번호6
  bonus       smallint not null check (bonus between 1 and 45),  -- 보너스(서비스)
  created_at  timestamptz not null default now()
);

-- -----------------------------------------------------
-- 2. 추출번호 테이블 (다음 회차용으로 생성한 번호)
-- -----------------------------------------------------
create table if not exists lotto.picks (
  id             bigint generated always as identity primary key,
  target_round   int not null,                                   -- 대상 회차
  n1             smallint not null check (n1 between 1 and 45),
  n2             smallint not null check (n2 between 1 and 45),
  n3             smallint not null check (n3 between 1 and 45),
  n4             smallint not null check (n4 between 1 and 45),
  n5             smallint not null check (n5 between 1 and 45),
  n6             smallint not null check (n6 between 1 and 45),
  method         text,                                           -- 추출 로직 이름 (예: 'random', 'hot_cold')
  created_at     timestamptz not null default now(),
  -- 아래는 추첨 후 채워지는 결과 컬럼
  matched_count  smallint,                                       -- 맞힌 개수 (0~6)
  bonus_matched  boolean,                                        -- 보너스 일치 여부
  prize_rank     smallint,                                       -- 등수 (1~5, 낙첨이면 null)
  checked_at     timestamptz                                     -- 확인한 시각
);

create index if not exists picks_target_round_idx on lotto.picks (target_round);

-- -----------------------------------------------------
-- 3. 당첨여부 확인 함수
--    사용법: select lotto.check_picks(1193);
--    해당 회차 당첨번호가 draws 에 들어간 뒤 실행
-- -----------------------------------------------------
create or replace function lotto.check_picks(p_round int)
returns int
language plpgsql
as $$
declare
  d   lotto.draws;
  win smallint[];
  cnt int;
begin
  select * into d from lotto.draws where round = p_round;
  if not found then
    raise exception '%회 당첨번호가 아직 없습니다', p_round;
  end if;

  win := array[d.n1, d.n2, d.n3, d.n4, d.n5, d.n6];

  update lotto.picks p
     set matched_count = m.c,
         bonus_matched = m.b,
         prize_rank = case
                        when m.c = 6            then 1
                        when m.c = 5 and m.b    then 2
                        when m.c = 5            then 3
                        when m.c = 4            then 4
                        when m.c = 3            then 5
                        else null
                      end,
         checked_at = now()
    from (
      select id,
             (select count(*) from unnest(array[n1, n2, n3, n4, n5, n6]) x
               where x = any(win))::smallint                as c,
             d.bonus = any(array[n1, n2, n3, n4, n5, n6])    as b
        from lotto.picks
       where target_round = p_round
    ) m
   where p.id = m.id;

  get diagnostics cnt = row_count;
  return cnt;   -- 확인한 건수
end;
$$;

-- -----------------------------------------------------
-- 4. 권한 + RLS
--    앱(anon 키)은 읽기만 가능, 쓰기는 서버(service_role)만
-- -----------------------------------------------------
grant usage on schema lotto to anon, authenticated, service_role;
grant select on all tables in schema lotto to anon, authenticated;
grant all    on all tables in schema lotto to service_role;
grant execute on function lotto.check_picks(int) to service_role;
revoke execute on function lotto.check_picks(int) from anon, authenticated, public;

alter table lotto.draws enable row level security;
alter table lotto.picks enable row level security;

drop policy if exists "draws read" on lotto.draws;
create policy "draws read" on lotto.draws for select using (true);

drop policy if exists "picks read" on lotto.picks;
create policy "picks read" on lotto.picks for select using (true);

-- 실행 후: Settings > API > Exposed schemas 에 lotto 추가
