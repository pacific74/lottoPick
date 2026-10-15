// 배치 작업: 수집 / 채점 / 추출
import {
  db, fetchWindow, sleep, expectedLatestRound, grade, METHODS,
} from './lib.mjs';

const SETS_PER_METHOD = Number(process.env.SETS_PER_METHOD || 5);

/** DB에 저장된 마지막 회차 (없으면 0) */
async function lastSavedRound(sb) {
  const { data, error } = await sb.from('draws')
    .select('round').order('round', { ascending: false }).limit(1);
  if (error) {
    throw new Error(`[Supabase 연결 실패] ${error.message} — URL/키 값, Data API에 lotto 스키마 노출 여부를 확인하세요`);
  }
  return data.length ? data[0].round : 0;
}

/**
 * 1) 당첨번호 수집
 * DB의 마지막 회차 다음부터 최신 회차까지 받아서 저장.
 * 처음 실행하면 1회부터 전부 채움 (약 1,200회, 몇 분 걸림).
 * @returns 새로 저장한 회차 번호 배열
 */
export async function collect() {
  const sb = db();
  const from = (await lastSavedRound(sb)) + 1;
  const to = expectedLatestRound();
  if (from > to) {
    console.log(`[수집] 이미 최신입니다 (${from - 1}회까지 저장됨)`);
    return [];
  }
  console.log(`[수집] ${from}회 ~ ${to}회 조회 시작`);

  const saved = [];
  let buffer = [];
  const flush = async () => {
    if (!buffer.length) return;
    const { error } = await sb.from('draws').upsert(buffer, { onConflict: 'round' });
    if (error) throw error;
    saved.push(...buffer.map((b) => b.round));
    console.log(`[수집] ${buffer[0].round}~${buffer.at(-1).round}회 저장`);
    buffer = [];
  };

  // 한 번 조회에 10개 회차가 오므로, cur+5 를 물어보면 cur ~ cur+9 를 받음
  const getWindow = async (ask) => {
    for (let attempt = 1; ; attempt++) {
      try {
        return await fetchWindow(ask);
      } catch (e) {
        if (attempt === 3) throw e;
        console.warn(`[수집] ${ask}회 근처 재시도 (${e.message})`);
        await sleep(2000 * attempt);
      }
    }
  };

  let cur = from;
  while (cur <= to) {
    // 먼저 cur+5 로 10개를 받고, 그 회차가 아직 추첨 전이라 빈 목록이면 cur 로 다시 물어봄
    const asks = [...new Set([Math.min(cur + 5, to), cur])];
    let next = cur;
    for (const ask of asks) {
      const fresh = (await getWindow(ask))
        .filter((d) => d.round >= cur && d.round <= to)
        .sort((a, b) => a.round - b.round);
      // 중간에 빠진 회차 없이 cur 부터 이어지는 것만 사용
      for (const d of fresh) {
        if (d.round !== next) break;
        buffer.push(d);
        next++;
      }
      if (next > cur) break;
    }
    if (next === cur) {
      console.log(`[수집] ${cur}회는 아직 결과가 없습니다. 여기서 멈춥니다.`);
      break;
    }
    cur = next;
    if (buffer.length >= 50) await flush();
    await sleep(200); // 동행복권 서버 부담 줄이기
  }
  await flush();
  return saved;
}

/**
 * 2) 채점: 해당 회차의 추출번호를 당첨번호와 비교해 결과 저장
 * @returns 채점한 건수
 */
export async function check(round) {
  const sb = db();
  const { data: draw, error: e1 } = await sb.from('draws')
    .select('*').eq('round', round).maybeSingle();
  if (e1) throw e1;
  if (!draw) {
    console.log(`[채점] ${round}회 당첨번호가 없어 건너뜁니다`);
    return 0;
  }
  const { data: picks, error: e2 } = await sb.from('picks')
    .select('*').eq('target_round', round);
  if (e2) throw e2;

  const now = new Date().toISOString();
  for (const p of picks) {
    const g = grade(p, draw);
    const { error } = await sb.from('picks')
      .update({ ...g, checked_at: now }).eq('id', p.id);
    if (error) throw error;
  }
  const wins = picks.map((p) => grade(p, draw).prize_rank).filter(Boolean);
  console.log(`[채점] ${round}회: ${picks.length}건 확인, 당첨 ${wins.length}건 ${wins.length ? '(' + wins.map((r) => r + '등').join(', ') + ')' : ''}`);
  return picks.length;
}

/**
 * 3) 추출: 다음 회차 번호를 방식별로 생성해 저장
 * 이미 해당 회차 추출번호가 있으면 다시 만들지 않음 (force=true 로 강제 가능)
 */
export async function generate(targetRound, { force = false } = {}) {
  const sb = db();
  const latest = await lastSavedRound(sb);
  const target = targetRound ?? latest + 1;

  if (!force) {
    const { count, error } = await sb.from('picks')
      .select('id', { count: 'exact', head: true })
      .eq('target_round', target).eq('source', 'batch'); // 앱에서 만든 번호는 제외
    if (error) throw error;
    if (count > 0) {
      console.log(`[추출] ${target}회 추출번호가 이미 ${count}건 있어 건너뜁니다`);
      return [];
    }
  }

  // 통계용 과거 데이터 (최신 회차가 앞에 오도록). 대상 회차 이전 것만 사용.
  const history = [];
  for (let offset = 0; ; offset += 1000) {
    const { data, error } = await sb.from('draws').select('*')
      .lt('round', target).order('round', { ascending: false })
      .range(offset, offset + 999);
    if (error) throw error;
    history.push(...data);
    if (data.length < 1000) break;
  }

  const rows = [];
  for (const [method, fn] of Object.entries(METHODS)) {
    for (let i = 0; i < SETS_PER_METHOD; i++) {
      const [n1, n2, n3, n4, n5, n6] = fn(history);
      rows.push({ target_round: target, n1, n2, n3, n4, n5, n6, method, source: 'batch' });
    }
  }
  const { error } = await sb.from('picks').insert(rows);
  if (error) throw error;
  console.log(`[추출] ${target}회 번호 ${rows.length}세트 저장 (방식별 ${SETS_PER_METHOD}세트)`);
  return rows;
}

/** 주간 전체 흐름: 수집 → 새 회차 채점 → 다음 회차 추출 */
export async function weekly() {
  const newRounds = await collect();
  // 처음 1회부터 채우는 경우엔 추출번호가 없으니 최근 회차만 채점
  for (const r of newRounds.slice(-3)) await check(r);
  await generate();
}
