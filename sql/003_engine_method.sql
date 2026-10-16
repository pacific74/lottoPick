-- =====================================================
-- 로또픽: 번호 추출 엔진(17가지 조건) 저장 허용
-- Supabase > SQL Editor 에 붙여넣고 Run (한 번만)
-- 002_app_picks.sql 을 먼저 실행한 상태여야 함
-- =====================================================

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
  -- 'engine' 추가 (번호 추출 엔진, 20게임 단위)
  if p_method is null or p_method not in ('engine', 'random', 'hot', 'cold', 'balanced') then
    raise exception '알 수 없는 추출 방식: %', p_method;
  end if;

  -- 회차당 앱 생성 한도: 엔진 20게임씩 여러 번 눌러도 되도록 1000세트
  select count(*) into v_cnt from lotto.picks where target_round = v_round and source = 'app';
  if v_cnt >= 1000 then
    raise exception '%회 앱 생성 한도(1000세트)를 넘었습니다', v_round;
  end if;

  insert into lotto.picks (target_round, n1, n2, n3, n4, n5, n6, method, source)
  values (v_round, v_sorted[1], v_sorted[2], v_sorted[3], v_sorted[4], v_sorted[5], v_sorted[6], p_method, 'app')
  returning * into r;
  return r;
end;
$$;

revoke all on function lotto.add_pick(int[], text) from public;
grant execute on function lotto.add_pick(int[], text) to anon, authenticated, service_role;
