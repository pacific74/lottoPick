// =====================================================================
// 로또픽 번호 추출 엔진 V2 — V1(engine.mjs)을 기본으로
//   · 번호 선택: 간격 평균 대비 60 / 30 / 10 비중 (V1 15번 대체)
//   · 동반번호: 2개 상위 20 / 3개 5세트 / 4개 1세트 (V1 4~9번 대체)
//   · 나머지(1·2·3·10·11·12·13·14·16·17)는 V1 통계 그대로
// claude/engine_rules.md 참고
// =====================================================================
import { buildStats, allocate } from './engine.mjs';

const key = (a) => a.join(',');
const decadeOf = (n) => (n < 10 ? 0 : n < 20 ? 1 : n < 30 ? 2 : n < 40 ? 3 : 4);

function pickWeighted(items, weightOf, rng) {
  let total = 0;
  for (const it of items) total += weightOf(it);
  if (total <= 0) return null;
  let r = rng() * total;
  for (const it of items) { r -= weightOf(it); if (r < 0) return it; }
  return items[items.length - 1];
}
const shuffle = (a, rng) => { for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(rng() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; };

/** 회차 목록 → 평균 간격, 최근 출현 후 지난 회차 */
function gapInfo(rounds, L, N) {
  const count = rounds.length;
  const since = L - rounds[count - 1];
  const avg = count >= 2 ? (rounds[count - 1] - rounds[0]) / (count - 1) : N; // 간격들의 평균
  return { count, since, avg };
}

/**
 * 60 / 30 / 10 비중 나누기
 * items: [{ since, avg, ... }]  baseW(item): 그룹 안에서의 상대 비중
 * → item.p (합 1)
 */
function split603010(items, baseW) {
  const over = items.filter((x) => x.since > x.avg);
  const rest = items.filter((x) => x.since <= x.avg)
    .sort((a, b) => Math.abs(a.since - a.avg) - Math.abs(b.since - b.avg));
  const nNear = Math.ceil(rest.length * 0.7);
  const near = rest.slice(0, nNear), recent = rest.slice(nNear);
  const groups = [[over, 0.6], [near, 0.3], [recent, 0.1]].filter(([g]) => g.length);
  const massSum = groups.reduce((a, [, m]) => a + m, 0); // 빈 그룹 비중은 나머지에 비례 배분
  for (const [g, m] of groups) {
    const s = g.reduce((a, x) => a + baseW(x), 0);
    for (const x of g) x.p = (m / massSum) * (baseW(x) / s);
  }
  for (const x of items) x.group = over.includes(x) ? 'over' : near.includes(x) ? 'near' : 'recent';
  return items;
}

export function buildStatsV2(draws, opts = {}) {
  const st = buildStats(draws, opts); // V1 통계 (제외 조합·합계·홀짝·번호대·이월수·제외 번호 등)
  const { L, freq, excluded } = st;
  const N = draws.length;

  // ---- 번호별 간격 → 60/30/10
  const roundsOf = [...Array(46)].map(() => []);
  for (const d of draws) for (const n of d.numbers) roundsOf[n].push(d.round);
  const nums = [];
  for (let n = 1; n <= 45; n++) {
    if (excluded.has(n) || roundsOf[n].length === 0) continue;
    nums.push({ n, ...gapInfo(roundsOf[n], L, N), freq: freq[n] });
  }
  split603010(nums, (x) => x.freq); // 그룹 안: 많이 나온 번호일수록 조금씩 높게
  const numW = Array(46).fill(0);
  for (const x of nums) numW[x.n] = x.p;

  // ---- 동반번호 회차 (V1 통계에 없는 회차 목록을 다시 모음)
  const comboRounds = { 2: new Map(), 3: new Map(), 4: new Map() };
  const combos = (src, k) => { const out = []; const rec = (s, c) => { if (c.length === k) { out.push(c.slice()); return; } for (let i = s; i < src.length; i++) { c.push(src[i]); rec(i + 1, c); c.pop(); } }; rec(0, []); return out; };
  for (const d of draws) for (const k of [2, 3, 4]) for (const c of combos(d.numbers, k)) {
    const kk = key(c); const e = comboRounds[k].get(kk);
    if (e) e.rounds.push(d.round); else comboRounds[k].set(kk, { nums: c, rounds: [d.round] });
  }
  const ranked = (k) => [...comboRounds[k].values()]
    .filter((e) => !e.nums.some((n) => excluded.has(n))) // 17
    .map((e) => ({ nums: e.nums, ...gapInfo(e.rounds, L, N) }))
    .sort((a, b) => b.count - a.count || b.since - a.since);

  // 2개: 자주 나온 순 상위 20 → 60/30/10, 60% 그룹은 오래 안 나왔을수록 가중치 ↑
  const allPairs = ranked(2);
  const pairs = allPairs.slice(0, 20);
  split603010(pairs, (x) => (x.since > x.avg ? (x.since / x.avg) ** 2 : 1));
  // 3개: 자주 나온 순, 평균 간격보다 오래 안 나온 것만 5세트
  const triples = ranked(3).filter((x) => x.count >= 2 && x.since > x.avg).slice(0, 5);
  triples.forEach((x) => { x.p = 1; });
  // 4개: 자주 나온 순 1세트
  const quads = ranked(4).slice(0, 1);
  quads.forEach((x) => { x.p = 1; });

  // ---- 묶음 추천: 번호 1개를 뽑을 때, 그 번호가 '많이 나왔지만 평균보다 오래 안 나온' 번호이고
  //      그 번호와 자주 같이 나온 동반번호(2개 조합)도 평균 간격보다 오래 안 나왔다면 같이 묶어서 뽑음
  const meanFreq = nums.reduce((a, x) => a + x.freq, 0) / (nums.length || 1);
  const bundle = Array.from({ length: 46 }, () => []);
  for (const x of nums) {
    if (!(x.since > x.avg && x.freq > meanFreq)) continue;
    const mine = allPairs.filter((c) => c.nums.includes(x.n));
    if (!mine.length) continue;
    const meanCount = mine.reduce((a, c) => a + c.count, 0) / mine.length;
    bundle[x.n] = mine
      .filter((c) => c.count > meanCount && c.since > c.avg)   // 자주 나왔지만 최근엔 안 나온 동반번호
      .sort((a, b) => b.count - a.count || b.since - a.since)
      .map((c) => ({ m: c.nums.find((v) => v !== x.n), count: c.count }));
  }

  return { ...st, numW, nums, pairs, triples, quads, bundle };
}

/** V2 로 games 개 (기본 20) 생성 — 반환 형식은 V1 generate 와 같음 */
export function generateV2(draws, opts = {}) {
  const rng = opts.rng || Math.random;
  const st = opts.stats || buildStatsV2(draws, opts);
  const { o, latest, excluded, banned, sumMin, sumMax, oddDist, decDist, carryDist, numW, pairs, triples, quads, bundle } = st;
  const G = o.games;
  const prevSet = new Set(latest.numbers);

  // 게임 배분: 4개 1 · 3개 5 · 2개 나머지 (후보가 모자라면 2개로)
  const nQuad = Math.min(1, quads.length), nTri = Math.min(5, triples.length);
  const sizes = [...Array(nQuad).fill(4), ...Array(nTri).fill(3), ...Array(G - nQuad - nTri).fill(2)];
  // 홀짝·이월수 게임 수 (V1 10·14번)
  const expand = (alloc) => alloc.flatMap((c, i) => Array(c).fill(i));
  const oddPool = expand(allocate(oddDist, G));
  const carryPool = expand(allocate(carryDist, G));

  const decMax = decDist.map((row) => Math.max(...row));
  const decAccept = (nums) => { const dc = [0, 0, 0, 0, 0]; nums.forEach((n) => dc[decadeOf(n)]++); let p = 1; for (let d = 0; d < 5; d++) p *= decDist[d][dc[d]] / decMax[d]; return p; };

  const games = [];
  const okOverlap = (nums) => games.every((g) => g.nums.filter((n) => nums.includes(n)).length <= o.maxOverlap);
  const valid = (nums) => { const s = nums.reduce((a, b) => a + b, 0); return s >= sumMin && s <= sumMax && !banned.has(key(nums)) && okOverlap(nums); };
  const pool = [...Array(45)].map((_, i) => i + 1).filter((n) => !excluded.has(n));
  const usedCombo = new Set();

  // 조합에 맞는 (홀수 개수, 이월수 개수) 를 남은 풀에서 고름
  function takeSpec(c) {
    const oddIn = c.nums.filter((n) => n % 2).length, evenIn = c.nums.length - oddIn;
    const prevIn = c.nums.filter((n) => prevSet.has(n)).length;
    const oi = shuffle([...oddPool.keys()], rng).find((i) => oddPool[i] >= oddIn && 6 - oddPool[i] >= evenIn);
    const ci = shuffle([...carryPool.keys()], rng).find((i) => carryPool[i] >= prevIn);
    if (oi === undefined || ci === undefined) return null;
    return { odd: oddPool[oi], carry: carryPool[ci], oi, ci };
  }

  function build(c, spec, useDecade) {
    const oddIn = c.nums.filter((n) => n % 2).length;
    const prevIn = c.nums.filter((n) => prevSet.has(n)).length;
    for (let b = 0; b < 40; b++) {
      const chosen = [...c.nums];
      let needOdd = spec.odd - oddIn, needEven = 6 - spec.odd - (c.nums.length - oddIn), needPrev = spec.carry - prevIn;
      let ok = true;
      while (chosen.length < 6) {
        const wantPrev = needPrev > 0;
        const cand = pool.filter((n) => !chosen.includes(n) && (wantPrev ? prevSet.has(n) : !prevSet.has(n)) && (n % 2 ? needOdd > 0 : needEven > 0));
        const n = pickWeighted(cand, (x) => numW[x], rng); // V2 번호 비중 60/30/10
        if (n == null) { ok = false; break; }
        chosen.push(n); if (n % 2) needOdd--; else needEven--; if (wantPrev) needPrev--;
        // 묶음 추천: 자주 같이 나온 순으로, 남은 칸·홀짝·이월수 조건에 맞는 동반번호 1개를 같이 넣음
        if (bundle[n].length && chosen.length < 6) {
          const slots = 6 - chosen.length;
          const mate = bundle[n].find(({ m }) => pool.includes(m) && !chosen.includes(m)
            && (m % 2 ? needOdd > 0 : needEven > 0)
            && (prevSet.has(m) ? needPrev > 0 : slots - 1 >= needPrev));
          if (mate) { chosen.push(mate.m); if (mate.m % 2) needOdd--; else needEven--; if (prevSet.has(mate.m)) needPrev--; }
        }
      }
      if (!ok) continue;
      chosen.sort((x, y) => x - y);
      if (!valid(chosen)) continue;
      if (useDecade && rng() > decAccept(chosen)) continue;
      return chosen;
    }
    return null;
  }

  for (const k of sizes) {
    let g = null;
    for (let t = 0; t < 60 && !g; t++) {
      const list = k === 4 ? quads : k === 3 ? triples : pairs;
      // 3·4개 조합은 20게임 안에서 한 번씩만 (겹침 ≤2 조건)
      const cands = k === 2 ? list : list.filter((x) => !usedCombo.has(key(x.nums)));
      const c = pickWeighted(cands.length ? cands : pairs, (x) => x.p, rng);
      if (!c) break;
      const spec = takeSpec(c);
      if (!spec) continue;
      const nums = build(c, spec, t < 40) ; // 40번 시도 뒤에는 번호대 확률 완화
      if (nums) {
        oddPool.splice(spec.oi, 1); carryPool.splice(spec.ci, 1);
        usedCombo.add(key(c.nums));
        g = { nums, combo: c, spec: { k: c.nums.length, odd: spec.odd, carry: spec.carry } };
      }
    }
    if (!g) { // 안전장치: 제외·필터 유지한 무작위
      for (let t = 0; t < 5000 && !g; t++) {
        const s = shuffle(pool.slice(), rng).slice(0, 6).sort((x, y) => x - y);
        if (valid(s)) g = { nums: s, combo: null, spec: null, fallback: true };
      }
    }
    if (g) games.push(g);
  }
  return { games, stats: st };
}

/** 같은 조합이 겹치지 않게 count 개 (20게임 × n번) */
export function generateMany(draws, count, gen, opts = {}) {
  const seen = new Set(), out = [];
  const stats = opts.stats;
  for (let guard = 0; out.length < count && guard < count; guard++) {
    for (const g of gen(draws, { ...opts, stats }).games) {
      const k = key(g.nums);
      if (out.length < count && !seen.has(k)) { seen.add(k); out.push(g); }
    }
  }
  return out;
}
