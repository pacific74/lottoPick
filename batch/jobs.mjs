// 배치 작업: 수집 / 채점 / 추출
import {
  db, fetchWindow, sleep, expectedLatestRound, grade, genRandom,
} from './lib.mjs';
import { generate as genV1, buildStats } from './engine.mjs';
import { generateV2 as genV2, buildStatsV2, generateMany } from './engine_v2.mjs';

// 금요일 생성 개수 (방식별). 0 이면 그 방식은 안 만듦
const COUNTS = {
  v1: Number(process.env.V1_COUNT ?? 1000),
  v2: Number(process.env.V2_COUNT ?? 1000),
  random: Number(process.env.RANDOM_COUNT ?? 0), // 무작위는 기본으로 안 만듦 (필요하면 RANDOM_COUNT=1000)
};

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
  const picks = [];
  for (let from = 0; ; from += 1000) {
    const { data, error: e2 } = await sb.from('picks')
      .select('id,n1,n2,n3,n4,n5,n6').eq('target_round', round)
      .order('id').range(from, from + 999);
    if (e2) throw e2;
    picks.push(...data);
    if (data.length < 1000) break;
  }

  const now = new Date().toISOString();
  const groups = new Map(); // "맞힌개수|보너스|등수" → id 목록
  for (const p of picks) {
    const g = grade(p, draw);
    const k = `${g.matched_count}|${g.bonus_matched}|${g.prize_rank}`;
    if (!groups.has(k)) groups.set(k, { g, ids: [] });
    groups.get(k).ids.push(p.id);
  }
  for (const { g, ids } of groups.values()) {
    for (let i = 0; i < ids.length; i += 200) {
      const { error } = await sb.from('picks')
        .update({ ...g, checked_at: now }).in('id', ids.slice(i, i + 200));
      if (error) throw error;
    }
  }
  const byRank = {};
  for (const { g, ids } of groups.values()) if (g.prize_rank) byRank[g.prize_rank] = (byRank[g.prize_rank] || 0) + ids.length;
  const summary = Object.keys(byRank).sort().map((r) => `${r}등 ${byRank[r]}`).join(', ');
  console.log(`[채점] ${round}회: ${picks.length}건 확인, 당첨 ${summary || '없음'}`);
  return picks.length;
}

/**
 * 3) 추출: 다음 회차 번호를 방식별로 생성해 저장
 * 이미 해당 회차 추출번호가 있으면 다시 만들지 않음 (force=true 로 강제 가능)
 */
export async function generate(targetRound, { force = false } = {}) {
  const sb = db();
  const latest = await lastSavedRound(sb);
  // 다음 추첨 회차: DB 최신+1 과 날짜 기준 중 큰 값 (수집이 늦어도 회차가 밀리지 않게)
  const target = targetRound ?? Math.max(latest + 1, expectedLatestRound() + 1);
  if (latest + 1 < target) console.warn(`[추출] 주의: DB 최신 ${latest}회 — ${target - 1}회까지 수집이 안 된 상태로 추출합니다`);

  // 통계용 과거 데이터 (회차 오름차순, 대상 회차 이전만)
  const history = [];
  for (let offset = 0; ; offset += 1000) {
    const { data, error } = await sb.from('draws').select('*')
      .lt('round', target).order('round', { ascending: true })
      .range(offset, offset + 999);
    if (error) throw error;
    history.push(...data);
    if (data.length < 1000) break;
  }
  const draws = history.map((d) => ({
    round: d.round,
    numbers: [d.n1, d.n2, d.n3, d.n4, d.n5, d.n6].sort((a, b) => a - b),
    bonus: d.bonus,
  }));

  const withBanned = (st, issued) => { for (const k of issued) st.banned.add(k); return st; };
  const makers = {
    v1: (n, issued) => generateMany(draws, n, genV1, { stats: withBanned(buildStats(draws), issued) }).map((g) => g.nums),
    v2: (n, issued) => generateMany(draws, n, genV2, { stats: withBanned(buildStatsV2(draws), issued) }).map((g) => g.nums),
    random: (n, issued) => { const seen = new Set(); while (seen.size < n) { const k = genRandom().join(','); if (!issued.has(k)) seen.add(k); } return [...seen].map((k) => k.split(',').map(Number)); },
  };

  // 이 회차에 이미 발급된 번호 (배치·앱 전부) — 6개가 모두 같은 조합은 다시 만들지 않음
  const issued = new Set();
  for (let from = 0; ; from += 1000) {
    const { data, error } = await sb.from('picks')
      .select('n1,n2,n3,n4,n5,n6').eq('target_round', target)
      .order('id').range(from, from + 999);
    if (error) throw error;
    for (const r of data) issued.add([r.n1, r.n2, r.n3, r.n4, r.n5, r.n6].sort((a, b) => a - b).join(','));
    if (data.length < 1000) break;
  }
  console.log(`[추출] ${target}회 이미 발급된 번호 ${issued.size}개는 피해서 만듭니다`);

  const made = {};
  for (const [method, n] of Object.entries(COUNTS)) {
    if (!n) continue;
    if (!force) {
      const { count, error } = await sb.from('picks')
        .select('id', { count: 'exact', head: true })
        .eq('target_round', target).eq('source', 'batch').eq('method', method);
      if (error) throw error;
      if (count > 0) { console.log(`[추출] ${target}회 ${method} 이미 ${count}건 있어 건너뜀`); continue; }
    }
    const made_nums = makers[method](n, issued);
    for (const nums of made_nums) issued.add(nums.join(',')); // 다음 방식(V2)은 V1 번호도 피함
    const rows = made_nums.map(([n1, n2, n3, n4, n5, n6]) =>
      ({ target_round: target, n1, n2, n3, n4, n5, n6, method, source: 'batch' }));
    for (let i = 0; i < rows.length; i += 500) {
      const { error } = await sb.from('picks').insert(rows.slice(i, i + 500));
      if (error) throw error;
    }
    made[method] = rows.length;
  }
  console.log(`[추출] ${target}회 저장: ${Object.entries(made).map(([m, c]) => `${m} ${c}개`).join(', ') || '새로 만든 것 없음'}`);
  return made;
}

/** 금요일 저녁: (가능하면) 수집 → 다음 회차 V1 엔진 1000개 · V2 엔진 1000개 */
export async function friday() {
  try { await collect(); } catch (e) { console.warn('[수집] 실패 — DB 에 있는 데이터로 계속:', e.message); }
  await generate();
}

/** 일요일 새벽: 수집 → 새 회차 채점 */
export async function sunday() {
  const newRounds = await collect();
  for (const r of newRounds.slice(-3)) await check(r);
}

/** 수동용 전체 흐름: 수집 → 새 회차 채점 → 다음 회차 추출 */
export async function weekly() {
  const newRounds = await collect();
  // 처음 1회부터 채우는 경우엔 추출번호가 없으니 최근 회차만 채점
  for (const r of newRounds.slice(-3)) await check(r);
  await generate();
}
