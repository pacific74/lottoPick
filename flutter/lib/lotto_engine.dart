// =====================================================================
// 로또픽 번호 추출 엔진 (조건 1~17) — 배치 batch/engine.mjs 와 같은 로직
//   generateEngine(draws) → 20게임
//   draws: 회차 오름차순, 마지막이 최신. 매번 draws 전체로 통계를 새로 계산.
// =====================================================================
import 'dart:math';

import 'lotto_repository.dart';

typedef CurveFn = double Function(double t);

/// 9번 곡선 (테스트 결과 4가지 모두 결과 차이 없음 → 기본 제곱)
final Map<String, CurveFn> engineCurves = {
  'linear': (t) => t,
  'pow2': (t) => t * t,
  'pow3': (t) => t * t * t,
  'exp': (t) => (exp(3 * t) - 1) / (exp(3) - 1),
};

class EngineOptions {
  final int games; // 기본 20게임
  final String curve; // 9번
  final double overBoost; // 8번 최대 간격 초과 조합 우대 배수
  final double singleWeight; // 7번 1번만 나온 조합 간격 가중치
  final double floor; // 6번 바닥값
  final int maxOverlap; // 13번 세트끼리 겹치는 번호 최대 개수
  const EngineOptions({
    this.games = 20,
    this.curve = 'pow2',
    this.overBoost = 3,
    this.singleWeight = 0.1,
    this.floor = 0.05,
    this.maxOverlap = 2,
  });
}

class EngineCombo {
  final List<int> nums;
  final int count;
  final int since;
  final bool over;
  final double w;
  EngineCombo(this.nums, this.count, this.since, this.over, this.w);
}

class EngineGame {
  final List<int> numbers;
  final EngineCombo? combo;
  final bool fallback;
  EngineGame(this.numbers, this.combo, {this.fallback = false});
}

class _Spec {
  final int k;
  final int odd;
  final int carry;
  _Spec(this.k, this.odd, this.carry);
}

int _decadeOf(int n) => n < 10 ? 0 : n < 20 ? 1 : n < 30 ? 2 : n < 40 ? 3 : 4;
String _key(List<int> a) => a.join(',');

List<List<int>> _combinations(List<int> src, int k) {
  final out = <List<int>>[];
  void rec(int s, List<int> cur) {
    if (cur.length == k) {
      out.add(List<int>.of(cur));
      return;
    }
    for (var i = s; i < src.length; i++) {
      cur.add(src[i]);
      rec(i + 1, cur);
      cur.removeLast();
    }
  }

  rec(0, <int>[]);
  return out;
}

/// 확률 분포 → 정수 게임 수 (큰 나머지 순 반올림)
List<int> allocateGames(List<double> probs, int total) {
  final raw = probs.map((p) => p * total).toList();
  final out = raw.map((v) => v.floor()).toList();
  final left = total - out.fold<int>(0, (a, b) => a + b);
  final order = List<int>.generate(raw.length, (i) => i)
    ..sort((a, b) => (raw[b] - raw[b].floor()).compareTo(raw[a] - raw[a].floor()));
  for (var j = 0; j < left; j++) {
    out[order[j % order.length]]++;
  }
  return out;
}

T? _pickWeighted<T>(List<T> items, double Function(T) weightOf, Random rng) {
  var total = 0.0;
  for (final it in items) {
    total += weightOf(it);
  }
  if (total <= 0 || items.isEmpty) return null;
  var r = rng.nextDouble() * total;
  for (final it in items) {
    r -= weightOf(it);
    if (r < 0) return it;
  }
  return items.last;
}

/// avoid: 이미 발급한 번호("1,2,3,4,5,6" 형식)는 다시 만들지 않음
List<EngineGame> generateEngine(List<Draw> draws,
    {EngineOptions o = const EngineOptions(), Random? rng, Set<String>? avoid}) {
  final rnd = rng ?? Random.secure();
  final n = draws.length;
  final latest = draws[n - 1];
  final prev2 = n >= 2 ? draws[n - 2] : null;
  final latestRound = latest.round;

  // 15 번호별 당첨 횟수
  final freq = List<int>.filled(46, 0);
  for (final d in draws) {
    for (final x in d.numbers) {
      freq[x]++;
    }
  }

  // 16 2회 연속 출현 번호 제외
  final excluded = latest.numbers.where((x) => prev2 != null && prev2.numbers.contains(x)).toSet();

  // 1·2·3 제외 조합
  List<int> ranked(bool most) {
    final nums = List<int>.generate(45, (i) => i + 1);
    nums.sort((a, b) {
      final diff = most ? freq[b] - freq[a] : freq[a] - freq[b];
      return diff != 0 ? diff : a - b;
    });
    return nums;
  }

  final top6 = ranked(true).take(6).toList()..sort();
  final bottom6 = ranked(false).take(6).toList()..sort();
  final banned = <String>{for (final d in draws) _key(d.numbers)};
  banned.add(_key(top6));
  banned.add(_key(bottom6));
  if (avoid != null) banned.addAll(avoid); // 이번 회차에 이미 발급한 번호와 6개 전부 같은 조합 제외

  // 11 합계 범위, 10 홀짝, 12 번호대, 14 이월수
  var sumMin = 1 << 30, sumMax = -1;
  final oddCnt = List<int>.filled(7, 0);
  final decCnt = List<List<int>>.generate(5, (_) => List<int>.filled(7, 0));
  final carryCnt = List<int>.filled(7, 0);
  for (var i = 0; i < n; i++) {
    final nums = draws[i].numbers;
    final s = nums.fold<int>(0, (a, b) => a + b);
    if (s < sumMin) sumMin = s;
    if (s > sumMax) sumMax = s;
    oddCnt[nums.where((x) => x.isOdd).length]++;
    final dc = List<int>.filled(5, 0);
    for (final x in nums) {
      dc[_decadeOf(x)]++;
    }
    for (var d = 0; d < 5; d++) {
      decCnt[d][dc[d]]++;
    }
    if (i > 0) carryCnt[nums.where((x) => draws[i - 1].numbers.contains(x)).length]++;
  }
  final oddDist = oddCnt.map((c) => c / n).toList();
  final decDist = decCnt.map((row) => row.map((c) => c / n).toList()).toList();
  final carryDist = carryCnt.map((c) => c / (n - 1)).toList();

  // 4·5·7 동반번호: 나온 회차 + 재출현 비율
  final combos = <int, Map<String, List<int>>>{2: {}, 3: {}, 4: {}}; // key → rounds
  final comboNums = <int, Map<String, List<int>>>{2: {}, 3: {}, 4: {}};
  final reHit = <int, int>{2: 0, 3: 0, 4: 0};
  for (var i = 0; i < n; i++) {
    final d = draws[i];
    for (final k in const [2, 3, 4]) {
      var hit = false;
      for (final c in _combinations(d.numbers, k)) {
        final kk = _key(c);
        final rounds = combos[k]![kk];
        if (rounds != null) {
          hit = true;
          rounds.add(d.round);
        } else {
          combos[k]![kk] = [d.round];
          comboNums[k]![kk] = c;
        }
      }
      if (i > 0 && hit) reHit[k] = reHit[k]! + 1;
    }
  }
  final p = <int, double>{for (final k in const [2, 3, 4]) k: reHit[k]! / (n - 1)};

  // 5·6·7·8·9 조합 가중치 (17: 제외 번호가 든 조합은 통째 제외)
  final curve = engineCurves[o.curve] ?? engineCurves['pow2']!;
  final comboList = <int, List<EngineCombo>>{};
  for (final k in const [2, 3, 4]) {
    final list = <EngineCombo>[];
    combos[k]!.forEach((kk, rounds) {
      final nums = comboNums[k]![kk]!;
      if (nums.any(excluded.contains)) return;
      final count = rounds.length;
      final since = latestRound - rounds.last;
      double gw;
      var over = false;
      if (count < 2) {
        gw = o.singleWeight;
      } else {
        var minGap = 1 << 30, maxGap = 0;
        for (var i = 1; i < count; i++) {
          final g = rounds[i] - rounds[i - 1];
          if (g < minGap) minGap = g;
          if (g > maxGap) maxGap = g;
        }
        double t;
        if (since > maxGap) {
          t = 1.0;
          over = true;
        } else if (maxGap == minGap) {
          t = since >= maxGap ? 1.0 : 0.0;
        } else {
          t = ((since - minGap) / (maxGap - minGap)).clamp(0.0, 1.0).toDouble();
        }
        gw = o.floor + (1 - o.floor) * curve(t);
      }
      final w = count * gw * (over ? o.overBoost : 1);
      list.add(EngineCombo(nums, count, since, over, w));
    });
    comboList[k] = list;
  }

  // 8 조합 크기별, 10 홀짝, 14 이월수 — 20게임 기준 배정
  final g = o.games;
  final pSum = p[2]! + p[3]! + p[4]!;
  final sizeAlloc = allocateGames([p[2]! / pSum, p[3]! / pSum, p[4]! / pSum], g);
  final oddAlloc = allocateGames(oddDist, g);
  final carryAlloc = allocateGames(carryDist, g);
  List<int> expand(List<int> alloc, List<int> vals) => [
        for (var i = 0; i < alloc.length; i++) ...List<int>.filled(alloc[i], vals[i]),
      ];
  final sizes = expand(sizeAlloc, const [2, 3, 4]);
  final odds = expand(oddAlloc, const [0, 1, 2, 3, 4, 5, 6])..shuffle(rnd);
  final carries = expand(carryAlloc, const [0, 1, 2, 3, 4, 5, 6])..shuffle(rnd);
  final specs = [for (var i = 0; i < sizes.length; i++) _Spec(sizes[i], odds[i], carries[i])];

  // 12 번호대 확률 (수락 확률 방식, 강제 배정 아님)
  final decMax = decDist.map((row) => row.reduce((a, b) => a > b ? a : b)).toList();
  double decAccept(List<int> nums) {
    final dc = List<int>.filled(5, 0);
    for (final x in nums) {
      dc[_decadeOf(x)]++;
    }
    var pr = 1.0;
    for (var d = 0; d < 5; d++) {
      pr *= decMax[d] > 0 ? decDist[d][dc[d]] / decMax[d] : 1;
    }
    return pr;
  }

  final prevSet = latest.numbers.toSet();
  final games = <EngineGame>[];
  bool okOverlap(List<int> nums) =>
      games.every((gm) => gm.numbers.where(nums.contains).length <= o.maxOverlap);
  bool valid(List<int> nums) {
    final s = nums.fold<int>(0, (a, b) => a + b);
    return s >= sumMin && s <= sumMax && !banned.contains(_key(nums)) && okOverlap(nums);
  }

  final pool = [for (var x = 1; x <= 45; x++) if (!excluded.contains(x)) x];

  EngineGame? tryBuild(_Spec spec, bool useDecade) {
    final list = comboList[spec.k]!;
    for (var a = 0; a < 40; a++) {
      final c = _pickWeighted<EngineCombo>(list, (x) => x.w, rnd);
      if (c == null) return null;
      final oddIn = c.nums.where((x) => x.isOdd).length;
      final prevIn = c.nums.where(prevSet.contains).length;
      if (oddIn > spec.odd || c.nums.length - oddIn > 6 - spec.odd || prevIn > spec.carry) continue;
      for (var b = 0; b < 30; b++) {
        final chosen = List<int>.of(c.nums);
        var needOdd = spec.odd - oddIn;
        var needEven = 6 - spec.odd - (c.nums.length - oddIn);
        var needPrev = spec.carry - prevIn;
        var ok = true;
        while (chosen.length < 6) {
          final wantPrev = needPrev > 0;
          final cand = pool
              .where((x) =>
                  !chosen.contains(x) &&
                  (wantPrev ? prevSet.contains(x) : !prevSet.contains(x)) &&
                  (x.isOdd ? needOdd > 0 : needEven > 0))
              .toList();
          final pick = _pickWeighted<int>(cand, (x) => freq[x].toDouble(), rnd); // 15
          if (pick == null) {
            ok = false;
            break;
          }
          chosen.add(pick);
          if (pick.isOdd) {
            needOdd--;
          } else {
            needEven--;
          }
          if (wantPrev) needPrev--;
        }
        if (!ok) continue;
        chosen.sort();
        if (!valid(chosen)) continue;
        if (useDecade && rnd.nextDouble() > decAccept(chosen)) continue;
        return EngineGame(chosen, c);
      }
    }
    return null;
  }

  for (final spec in specs) {
    EngineGame? gm;
    for (var t = 0; t < 30 && gm == null; t++) {
      gm = tryBuild(spec, true);
    }
    for (var t = 0; t < 30 && gm == null; t++) {
      gm = tryBuild(spec, false);
    }
    // 마지막 안전장치: 제외·필터는 유지하고 무작위
    for (var t = 0; t < 5000 && gm == null; t++) {
      final s = (List<int>.of(pool)..shuffle(rnd)).take(6).toList()..sort();
      if (valid(s)) gm = EngineGame(s, null, fallback: true);
    }
    if (gm != null) games.add(gm);
  }
  return games;
}
