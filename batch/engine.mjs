// =====================================================================
// 로또픽 번호 추출 엔진 (조건 1~17)  — claude/engine_rules.md 참고
//   generate(draws, opts) → 20게임
//   draws: [{ round, numbers:[6개 오름차순], bonus }]  회차 오름차순, 마지막이 최신
//   매번 draws 전체로 통계를 새로 계산 (조건 공통)
// =====================================================================

export const CURVES = {
  linear: (t) => t,
  pow2: (t) => t * t,
  pow3: (t) => t * t * t,
  exp: (t) => (Math.exp(3 * t) - 1) / (Math.exp(3) - 1),
};

const DEFAULTS = {
  games: 20,          // 기본 20게임
  curve: 'pow2',      // 9번 곡선 (테스트 후 결정)
  overBoost: 3,       // 8번 최대 간격 초과 조합 우대 배수
  singleWeight: 0.1,  // 7번: 1번만 나온 조합의 간격 가중치 (기본 비중 1 × 0.1 → 극히 낮게)
  floor: 0.05,        // 6번: 최소 간격 근처에서도 0 이 되지 않게 하는 바닥값
  maxOverlap: 2,      // 13번: 세트끼리 겹치는 번호 최대 2개
};

const key = (a) => a.join(',');
const decadeOf = (n) => (n < 10 ? 0 : n < 20 ? 1 : n < 30 ? 2 : n < 40 ? 3 : 4);

function combinations(src, k) {
  const out = [];
  const rec = (s, cur) => {
    if (cur.length === k) { out.push(cur.slice()); return; }
    for (let i = s; i < src.length; i++) { cur.push(src[i]); rec(i + 1, cur); cur.pop(); }
  };
  rec(0, []);
  return out;
}

/** 확률 분포 → 정수 게임 수 (큰 나머지 순 반올림) */
export function allocate(probs, total) {
  const raw = probs.map((p) => p * total);
  const out = raw.map(Math.floor);
  let left = total - out.reduce((a, b) => a + b, 0);
  const order = raw.map((v, i) => [v - Math.floor(v), i]).sort((a, b) => b[0] - a[0]);
  for (let j = 0; j < left; j++) out[order[j % order.length][1]]++;
  return out;
}

function pickWeighted(items, weightOf, rng) {
  let total = 0;
  for (const it of items) total += weightOf(it);
  if (total <= 0) return null;
  let r = rng() * total;
  for (const it of items) { r -= weightOf(it); if (r < 0) return it; }
  return items[items.length - 1];
}

function shuffle(a, rng) {
  for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(rng() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; }
  return a;
}

// ------------------------------------------------------------------ 통계
export function buildStats(draws, opts = {}) {
  const o = { ...DEFAULTS, ...opts };
  const latest = draws[draws.length - 1];
  const prev2 = draws[draws.length - 2];
  const L = latest.round;
  const N = draws.length;

  // 15 번호별 당첨 횟수
  const freq = Array(46).fill(0);
  for (const d of draws) for (const n of d.numbers) freq[n]++;

  // 16 2회 연속 출현 번호 제외
  const excluded = new Set(latest.numbers.filter((n) => prev2 && prev2.numbers.includes(n)));

  // 1·2·3 제외 조합 (완전히 같은 6개)
  const ranked = (most) => [...Array(45)].map((_, i) => i + 1)
    .sort((a, b) => (most ? freq[b] - freq[a] : freq[a] - freq[b]) || a - b);
  const top6 = ranked(true).slice(0, 6).sort((a, b) => a - b);
  const bottom6 = ranked(false).slice(0, 6).sort((a, b) => a - b);
  const banned = new Set(draws.map((d) => key(d.numbers)));
  banned.add(key(top6)); banned.add(key(bottom6));

  // 11 합계 범위
  let sumMin = Infinity, sumMax = -Infinity;
  // 10 홀짝 분포, 12 번호대별 개수 분포, 14 이월수 분포
  const oddCnt = Array(7).fill(0);
  const decCnt = [...Array(5)].map(() => Array(7).fill(0));
  const carryCnt = Array(7).fill(0);
  for (let i = 0; i < N; i++) {
    const nums = draws[i].numbers;
    const s = nums.reduce((a, b) => a + b, 0);
    if (s < sumMin) sumMin = s; if (s > sumMax) sumMax = s;
    oddCnt[nums.filter((n) => n % 2).length]++;
    const dc = [0, 0, 0, 0, 0]; nums.forEach((n) => dc[decadeOf(n)]++);
    dc.forEach((c, d) => decCnt[d][c]++);
    if (i > 0) carryCnt[nums.filter((n) => draws[i - 1].numbers.includes(n)).length]++;
  }
  const oddDist = oddCnt.map((c) => c / N);
  const decDist = decCnt.map((row) => row.map((c) => c / N));
  const carryDist = carryCnt.map((c) => c / (N - 1));

  // 4·5·7 동반번호(2·3·4개 조합): 나온 회차 + 재출현 비율
  const combos = { 2: new Map(), 3: new Map(), 4: new Map() };
  const reHit = { 2: 0, 3: 0, 4: 0 };
  for (let i = 0; i < N; i++) {
    const d = draws[i];
    for (const k of [2, 3, 4]) {
      const cs = combinations(d.numbers, k);
      let hit = false;
      for (const c of cs) {
        const kk = key(c);
        const e = combos[k].get(kk);
        if (e) { hit = true; e.rounds.push(d.round); } else combos[k].set(kk, { nums: c, rounds: [d.round] });
      }
      if (i > 0 && hit) reHit[k]++;
    }
  }
  const P = { 2: reHit[2] / (N - 1), 3: reHit[3] / (N - 1), 4: reHit[4] / (N - 1) };

  // 5·6·7·8·9 조합 가중치
  const curve = CURVES[o.curve] || CURVES.pow2;
  const comboList = {};
  for (const k of [2, 3, 4]) {
    const list = [];
    for (const e of combos[k].values()) {
      if (e.nums.some((n) => excluded.has(n))) continue; // 17
      const count = e.rounds.length;
      const last = e.rounds[count - 1];
      const since = L - last;
      let gw, over = false, minGap = null, maxGap = null;
      if (count < 2) {
        gw = o.singleWeight;
      } else {
        minGap = Infinity; maxGap = 0;
        for (let i = 1; i < count; i++) {
          const g = e.rounds[i] - e.rounds[i - 1];
          if (g < minGap) minGap = g; if (g > maxGap) maxGap = g;
        }
        let t;
        if (since > maxGap) { t = 1; over = true; }
        else if (maxGap === minGap) t = since >= maxGap ? 1 : 0;
        else t = Math.min(1, Math.max(0, (since - minGap) / (maxGap - minGap)));
        gw = o.floor + (1 - o.floor) * curve(t);
      }
      const w = count * gw * (over ? o.overBoost : 1);
      list.push({ nums: e.nums, count, since, minGap, maxGap, over, w });
    }
    comboList[k] = list;
  }

  return { o, latest, L, freq, excluded, top6, bottom6, banned, sumMin, sumMax, oddDist, decDist, carryDist, P, comboList };
}

// ------------------------------------------------------------------ 생성
export function generate(draws, opts = {}) {
  const rng = opts.rng || Math.random;
  const st = buildStats(draws, opts);
  const { o, latest, freq, excluded, banned, sumMin, sumMax, oddDist, decDist, carryDist, P, comboList } = st;
  const G = o.games;
  const prevSet = new Set(latest.numbers);

  // 8 조합 크기별 게임 수 (P2·P3·P4 비율), 10 홀짝, 14 이월수 — 20게임 기준 배정
  const pSum = P[2] + P[3] + P[4];
  const sizeAlloc = allocate([P[2] / pSum, P[3] / pSum, P[4] / pSum], G);
  const oddAlloc = allocate(oddDist, G);
  const carryAlloc = allocate(carryDist, G);
  const expand = (alloc, vals) => alloc.flatMap((c, i) => Array(c).fill(vals[i]));
  const sizes = expand(sizeAlloc, [2, 3, 4]);
  const odds = shuffle(expand(oddAlloc, [0, 1, 2, 3, 4, 5, 6]), rng);
  const carries = shuffle(expand(carryAlloc, [0, 1, 2, 3, 4, 5, 6]), rng);
  const specs = sizes.map((k, i) => ({ k, odd: odds[i], carry: carries[i] }));

  // 12 번호대 확률: 수락 확률 = Π P(번호대 d 에 c개) / Π max
  const decMax = decDist.map((row) => Math.max(...row));
  const decAccept = (nums) => {
    const dc = [0, 0, 0, 0, 0]; nums.forEach((n) => dc[decadeOf(n)]++);
    let p = 1; for (let d = 0; d < 5; d++) p *= decDist[d][dc[d]] / decMax[d];
    return p;
  };

  const games = [];
  const okOverlap = (nums) => games.every((g) => g.nums.filter((n) => nums.includes(n)).length <= o.maxOverlap);
  const valid = (nums) => {
    const s = nums.reduce((a, b) => a + b, 0);
    return s >= sumMin && s <= sumMax && !banned.has(key(nums)) && okOverlap(nums);
  };

  const pool = [...Array(45)].map((_, i) => i + 1).filter((n) => !excluded.has(n));

  // 동반번호 + 조건에 맞춰 나머지 채우기
  function tryBuild(spec, useDecade) {
    const list = comboList[spec.k];
    for (let a = 0; a < 40; a++) {
      const c = pickWeighted(list, (x) => x.w, rng);
      if (!c) return null;
      const oddIn = c.nums.filter((n) => n % 2).length;
      const prevIn = c.nums.filter((n) => prevSet.has(n)).length;
      if (oddIn > spec.odd || c.nums.length - oddIn > 6 - spec.odd || prevIn > spec.carry) continue;
      for (let b = 0; b < 30; b++) {
        const chosen = [...c.nums];
        let needOdd = spec.odd - oddIn, needEven = 6 - spec.odd - (c.nums.length - oddIn);
        let needPrev = spec.carry - prevIn;
        let ok = true;
        while (chosen.length < 6) {
          const wantPrev = needPrev > 0;
          const cand = pool.filter((n) => !chosen.includes(n)
            && (wantPrev ? prevSet.has(n) : !prevSet.has(n))
            && (n % 2 ? needOdd > 0 : needEven > 0));
          const n = pickWeighted(cand, (x) => freq[x], rng); // 15
          if (n == null) { ok = false; break; }
          chosen.push(n);
          if (n % 2) needOdd--; else needEven--;
          if (wantPrev) needPrev--;
        }
        if (!ok) continue;
        chosen.sort((x, y) => x - y);
        if (!valid(chosen)) continue;
        if (useDecade && rng() > decAccept(chosen)) continue;
        return { nums: chosen, combo: c, spec };
      }
    }
    return null;
  }

  for (const spec of specs) {
    let g = null;
    for (let t = 0; t < 30 && !g; t++) g = tryBuild(spec, true);
    for (let t = 0; t < 30 && !g; t++) g = tryBuild(spec, false); // 번호대 확률 완화
    if (!g) { // 마지막 안전장치: 조건 일부 완화한 무작위 (제외·필터는 유지)
      for (let t = 0; t < 5000 && !g; t++) {
        const s = shuffle(pool.slice(), rng).slice(0, 6).sort((x, y) => x - y);
        if (valid(s)) g = { nums: s, combo: null, spec, fallback: true };
      }
    }
    if (g) games.push(g);
  }
  return { games, stats: st, specs };
}
