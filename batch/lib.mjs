// 공통 모듈: Supabase 연결, 동행복권 조회, 채점/추출 로직
import { createClient } from '@supabase/supabase-js';

// ---------- Supabase ----------
export function db() {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) {
    throw new Error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 환경변수가 없습니다 (.env 확인)');
  }
  return createClient(url, key, {
    db: { schema: 'lotto' },
    auth: { persistSession: false },
  });
}

// ---------- 회차 계산 ----------
// 1회차: 2002-12-07(토) 20:45 KST. 추첨 후 결과가 올라오는 시간을 고려해 21:00 KST 기준.
const ROUND1_UTC = Date.UTC(2002, 11, 7, 12, 0); // 2002-12-07 21:00 KST
const WEEK = 7 * 24 * 60 * 60 * 1000;

/** 지금 시점까지 추첨이 끝났어야 하는 마지막 회차 */
export function expectedLatestRound(now = Date.now()) {
  return Math.floor((now - ROUND1_UTC) / WEEK) + 1;
}

// ---------- 동행복권 조회 ----------
// 2026년 개편된 사이트(/lt645/result)가 내부적으로 쓰는 주소.
// srchLtEpsd=N 을 주면 N 근처 10개 회차를 돌려줌 (예: 20 → 15~24, 1 → 1~10).
// 아직 추첨 전인 회차를 주면 빈 목록.
const DH_BASE = 'https://www.dhlottery.co.kr';
const DH_PAGE = DH_BASE + '/lt645/result';
const DH_API = DH_BASE + '/lt645/selectPstLt645InfoNew.do?srchDir=center&srchLtEpsd=';
const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36';

let cookie = '';
/** 결과 페이지를 한 번 열어 세션 쿠키를 받아 둠 (브라우저처럼 보이게) */
async function warmUp() {
  if (cookie) return;
  const res = await fetch(DH_PAGE, { headers: { 'User-Agent': UA } });
  const set = res.headers.getSetCookie?.() ?? [];
  cookie = set.map((c) => c.split(';')[0]).join('; ');
}

const ymd = (s) => `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}`;

/** round 근처 10개 회차 당첨번호 조회 */
export async function fetchWindow(round) {
  await warmUp();
  const res = await fetch(DH_API + round + '&_=' + Date.now(), {
    headers: {
      'User-Agent': UA,
      Accept: 'application/json, text/javascript, */*; q=0.01',
      'X-Requested-With': 'XMLHttpRequest',
      Referer: DH_PAGE,
      ...(cookie ? { Cookie: cookie } : {}),
    },
  });
  if (!res.ok) throw new Error(`${round}회 근처 조회 실패: HTTP ${res.status}`);
  const text = await res.text();
  let j;
  try {
    j = JSON.parse(text);
  } catch {
    throw new Error(
      `${round}회 응답이 JSON이 아닙니다 (동행복권이 차단했거나 주소가 바뀌었을 수 있음): ${text.trim().slice(0, 120)}`
    );
  }
  const list = j?.data?.list;
  if (!Array.isArray(list)) {
    throw new Error(`${round}회 응답 형식이 예상과 다릅니다: ${text.slice(0, 120)}`);
  }
  return list.map((x) => ({
    round: x.ltEpsd,
    draw_date: ymd(String(x.ltRflYmd)),
    n1: x.tm1WnNo, n2: x.tm2WnNo, n3: x.tm3WnNo,
    n4: x.tm4WnNo, n5: x.tm5WnNo, n6: x.tm6WnNo,
    bonus: x.bnsWnNo,
  }));
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------- 채점 ----------
export const nums = (row) => [row.n1, row.n2, row.n3, row.n4, row.n5, row.n6];

/** 추출번호 1세트를 당첨번호와 비교 */
export function grade(pick, draw) {
  const win = new Set(nums(draw));
  const mine = nums(pick);
  const matched = mine.filter((n) => win.has(n)).length;
  const bonus = mine.includes(draw.bonus);
  let rank = null;
  if (matched === 6) rank = 1;
  else if (matched === 5 && bonus) rank = 2;
  else if (matched === 5) rank = 3;
  else if (matched === 4) rank = 4;
  else if (matched === 3) rank = 5;
  return { matched_count: matched, bonus_matched: bonus, prize_rank: rank };
}

// ---------- 번호 추출 로직 ----------
// 로또는 매 회 독립 추첨이라 어떤 방법도 당첨 확률을 올려 주지는 않습니다.
// 여러 방식을 기록해 두고 실제 성적을 비교하는 용도입니다.

function pickWeighted(weights, count) {
  const chosen = new Set();
  while (chosen.size < count) {
    const pool = [];
    let total = 0;
    for (let n = 1; n <= 45; n++) {
      if (chosen.has(n)) continue;
      total += weights[n];
      pool.push([n, total]);
    }
    const r = Math.random() * total;
    chosen.add(pool.find(([, acc]) => r < acc)[0]);
  }
  return [...chosen].sort((a, b) => a - b);
}

const flat = () => Array.from({ length: 46 }, (_, i) => (i === 0 ? 0 : 1));

/** 완전 무작위 */
export function genRandom() {
  return pickWeighted(flat(), 6);
}

/** 최근 N회 많이 나온 번호에 가중치 */
export function genHot(history, recent = 100) {
  const w = flat();
  for (const d of history.slice(0, recent)) for (const n of nums(d)) w[n] += 1;
  return pickWeighted(w, 6);
}

/** 최근 오래 안 나온 번호에 가중치 */
export function genCold(history) {
  const w = flat();
  const lastSeen = Array(46).fill(history.length);
  history.forEach((d, idx) => {
    for (const n of nums(d)) if (lastSeen[n] > idx) lastSeen[n] = idx;
  });
  for (let n = 1; n <= 45; n++) w[n] = 1 + lastSeen[n];
  return pickWeighted(w, 6);
}

/** 무작위 + 조건 필터 (홀짝 2~4개, 합계 100~175, 연속번호 3개 이상 제외) */
export function genBalanced() {
  for (let i = 0; i < 10000; i++) {
    const s = genRandom();
    const odd = s.filter((n) => n % 2).length;
    const sum = s.reduce((a, b) => a + b, 0);
    let run = 1, maxRun = 1;
    for (let k = 1; k < 6; k++) {
      run = s[k] === s[k - 1] + 1 ? run + 1 : 1;
      maxRun = Math.max(maxRun, run);
    }
    if (odd >= 2 && odd <= 4 && sum >= 100 && sum <= 175 && maxRun < 3) return s;
  }
  return genRandom();
}

export const METHODS = {
  random: () => genRandom(),
  hot: (h) => genHot(h),
  cold: (h) => genCold(h),
  balanced: () => genBalanced(),
};
