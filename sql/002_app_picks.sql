-- =====================================================
-- 로또픽 v2: 앱에서 "다음 회차 번호 생성" 저장 기능
-- Supabase > SQL Editor 에 붙여넣고 Run (한 번만)
-- =====================================================

-- 1) 추출번호가 배치에서 만든 것인지 앱에서 만든 것인지 구분
alter table lotto.picks add column if not exists source text not null default 'batch';
create index if not exists picks_round_source_idx on lotto.picks (target_round, source);

-- 2) 앱 전용 저장 함수
--    앱(anon 키)은 테이블에 직접 쓰지 못하고, 이 함수로만 한 세트씩 저장 가능.
--    회차는 서버가 정함(다음 추첨 회차), 번호·방식 검증, 회차당 500세트 제한.
create or replace function lotto.add_pick(p_numbers int[], p_method text)
returns lotto.picks
language plpgsql
security definer
set search_path = lotto, public
as $$
declare
  v_round  int;
  v_sorted int[];
  v_cnt    int;
  r        lotto.picks;
begin
  -- 다음 추첨 회차: 날짜 기준(1회 = 2002-12-07 21:00 KST)과 DB 최신회차+1 중 큰 값
  select greatest(
           floor(extract(epoch from (now() - timestamptz '2002-12-07 21:00:00+09')) / 604800)::int + 2,
           coalesce(max(round), 0) + 1)
    into v_round
    from lotto.draws;

  if p_numbers is null or coalesce(array_length(p_numbers, 1), 0) <> 6 then
    raise exception '번호는 6개여야 합니다';
  end if;
  select array_agg(distinct x order by x) into v_sorted from unnest(p_numbers) as x;
  if array_length(v_sorted, 1) <> 6 or v_sorted[1] < 1 or v_sorted[6] > 45 then
    raise exception '1~45 사이 서로 다른 번호 6개여야 합니다';
  end if;
  if p_method is null or p_method not in ('random', 'hot', 'cold', 'balanced') then
    raise exception '알 수 없는 추출 방식: %', p_method;
  end if;

  select count(*) into v_cnt from lotto.picks where target_round = v_round and source = 'app';
  if v_cnt >= 500 then
    raise exception '%회 앱 생성 한도(500세트)를 넘었습니다', v_round;
  end if;

  insert into lotto.picks (target_round, n1, n2, n3, n4, n5, n6, method, source)
  values (v_round, v_sorted[1], v_sorted[2], v_sorted[3], v_sorted[4], v_sorted[5], v_sorted[6], p_method, 'app')
  returning * into r;
  return r;
end;
$$;

revoke all on function lotto.add_pick(int[], text) from public;
grant execute on function lotto.add_pick(int[], text) to anon, authenticated, service_role;

-- 실행 후: Integrations > Data API > Settings > Exposed functions 에서
--          lotto.add_pick 이 켜져 있는지 확인 (꺼져 있으면 켜기)
