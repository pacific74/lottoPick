// =====================================================================
// 로또픽 번호 추출 엔진 V2 — 배치 batch/engine_v2.mjs 와 같은 로직
//   V1(lotto_engine.dart)을 기본으로
//   · 번호 선택: 간격 평균 대비 60 / 30 / 10 비중 (V1 15번 대체)
//   · 동반번호: 2개 상위 20 / 3개 5세트 / 4개 1세트 (V1 4~9번 대체)
//   · 나머지(1·2·3·10·11·12·13·14·16·17)는 V1 그대로
//   generateEngineV2(draws) → 20게임
// =====================================================================
import 'dart:math';

import 'lotto_engine.dart';
import 'lotto_repository.dart';

int _dec(int n) => n < 10 ? 0 : n < 20 ? 1 : n < 30 ? 2 : n < 40 ? 3 : 4;
String _k(List<int> a) => a.join(',');

List<List<int>> _combos(List<int> src, int k) {
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

T? _pick<T>(List<T> items, double Function(T) weightOf, Random rng) {
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

/// 번호 또는 동반번호 1개의 간격 정보
class _Item {
  final List<int> nums;
  final int count; // 나온 횟수
  final int since; // 최근 출현 후 지난 회차
  final double avg; // 회차 간격 평균
  double p = 0; // 뽑힐 비중
  _Item(this.nums, this.count, this.since, this.avg);
}

_Item _gapItem(List<int> nums, List<int> rounds, int latestRound, int n) {
  final count = rounds.length;
  final since = latestRound - rounds.last;
  final avg = count >= 2 ? (rounds.last - rounds.first) / (count - 1) : n.toDouble();
  return _Item(nums, count, since, avg);
}

/// 60 / 30 / 10 비중 나누기 (빈 그룹 비중은 나머지 그룹에 비례 배분)
void _split603010(List<_Item> items, double Function(_Item) baseW) {
  final over = items.where((x) => x.since > x.avg).toList();
  final rest = items.where((x) => x.since <= x.avg).toList()
    ..sort((a, b) => (a.since - a.avg).abs().compareTo((b.since - b.avg).abs()));
  final nNear = (rest.length * 0.7).ceil();
  final near = rest.take(nNear).toList();
  final recent = rest.skip(nNear).toList();
  final groups = <(List<_Item>, double)>[(over, 0.6), (near, 0.3), (recent, 0.1)]
      .where((g) => g.$1.isNotEmpty)
      .toList();
  final massSum = groups.fold<double>(0, (a, g) => a + g.$2);
  for (final (g, m) in groups) {
    final s = g.fold<double>(0, (a, x) => a + baseW(x));
    for (final x in g) {
      x.p = s > 0 ? (m / massSum) * (baseW(x) / s) : 0;
    }
  }
}

List<EngineGame> generateEngineV2(List<Draw> draws, {EngineOptions o = const EngineOptions(), Random? rng}) {
  final rnd = rng ?? Random.secure();
  final n = draws.length;
  final latest = draws[n - 1];
  final prev2 = n >= 2 ? draws[n - 2] : null;
  final latestRound = latest.round;

  // ---- V1 공통 통계
  final freq = List<int>.filled(46, 0);
  final roundsOf = List<List<int>>.generate(46, (_) => <int>[]);
  for (final d in draws) {
    for (final x in d.numbers) {
      freq[x]++;
      roundsOf[x].add(d.round);
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

  final banned = <String>{for (final d in draws) _k(d.numbers)};
  banned.add(_k(ranked(true).take(6).toList()..sort()));
  banned.add(_k(ranked(false).take(6).toList()..sort()));

  // 11 합계, 10 홀짝, 12 번호대, 14 이월수
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
      dc[_dec(x)]++;
    }
    for (var d = 0; d < 5; d++) {
      decCnt[d][dc[d]]++;
    }
    if (i > 0) carryCnt[nums.where((x) => draws[i - 1].numbers.contains(x)).length]++;
  }
  final oddDist = oddCnt.map((c) => c / n).toList();
  final decDist = decCnt.map((row) => row.map((c) => c / n).toList()).toList();
  final carryDist = carryCnt.map((c) => c / (n - 1)).toList();

  // ---- V2 번호 비중: 60/30/10, 그룹 안에서는 많이 나온 번호일수록 조금씩 높게
  final numItems = <_Item>[
    for (var x = 1; x <= 45; x++)
      if (!excluded.contains(x) && roundsOf[x].isNotEmpty) _gapItem([x], roundsOf[x], latestRound, n),
  ];
  _split603010(numItems, (x) => freq[x.nums[0]].toDouble());
  final numW = List<double>.filled(46, 0);
  for (final x in numItems) {
    numW[x.nums[0]] = x.p;
  }

  // ---- 동반번호 회차
  final comboRounds = <int, Map<String, List<int>>>{2: {}, 3: {}, 4: {}};
  final comboNums = <int, Map<String, List<int>>>{2: {}, 3: {}, 4: {}};
  for (final d in draws) {
    for (final k in const [2, 3, 4]) {
      for (final c in _combos(d.numbers, k)) {
        final kk = _k(c);
        final r = comboRounds[k]![kk];
        if (r != null) {
          r.add(d.round);
        } else {
          comboRounds[k]![kk] = [d.round];
          comboNums[k]![kk] = c;
        }
      }
    }
  }
  List<_Item> rankedCombos(int k) {
    final list = <_Item>[];
    comboRounds[k]!.forEach((kk, rounds) {
      final nums = comboNums[k]![kk]!;
      if (nums.any(excluded.contains)) return; // 17
      list.add(_gapItem(nums, rounds, latestRound, n));
    });
    list.sort((a, b) => b.count != a.count ? b.count - a.count : b.since - a.since);
    return list;
  }

  // 2개: 자주 나온 순 상위 20 → 60/30/10, 60% 그룹은 오래 안 나왔을수록 가중치 ↑
  final pairs = rankedCombos(2).take(20).toList();
  _split603010(pairs, (x) => x.since > x.avg ? pow(x.since / x.avg, 2).toDouble() : 1.0);
  // 3개: 자주 나온 순, 평균 간격보다 오래 안 나온 것만 5세트
  final triples = rankedCombos(3).where((x) => x.count >= 2 && x.since > x.avg).take(5).toList();
  for (final x in triples) {
    x.p = 1;
  }
  // 4개: 자주 나온 순 1세트
  final quads = rankedCombos(4).take(1).toList();
  for (final x in quads) {
    x.p = 1;
  }

  // ---- 20게임 배분: 4개 1 · 3개 5 · 2개 나머지
  final g = o.games;
  final nQuad = min(1, quads.length), nTri = min(5, triples.length);
  final sizes = [
    ...List<int>.filled(nQuad, 4),
    ...List<int>.filled(nTri, 3),
    ...List<int>.filled(g - nQuad - nTri, 2),
  ];
  List<int> expand(List<int> alloc) => [
        for (var i = 0; i < alloc.length; i++) ...List<int>.filled(alloc[i], i),
      ];
  final oddPool = expand(allocateGames(oddDist, g)); // 10 홀수 개수
  final carryPool = expand(allocateGames(carryDist, g)); // 14 이월수 개수

  final decMax = decDist.map((row) => row.reduce((a, b) => a > b ? a : b)).toList();
  double decAccept(List<int> nums) {
    final dc = List<int>.filled(5, 0);
    for (final x in nums) {
      dc[_dec(x)]++;
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
    return s >= sumMin && s <= sumMax && !banned.contains(_k(nums)) && okOverlap(nums);
  }

  final pool = [for (var x = 1; x <= 45; x++) if (!excluded.contains(x)) x];
  final usedCombo = <String>{};

  // 조합에 맞는 (홀수 개수, 이월수 개수) 를 남은 풀에서 고름 → [홀수, 이월수, 홀수 위치, 이월수 위치]
  List<int>? takeSpec(_Item c) {
    final oddIn = c.nums.where((x) => x.isOdd).length;
    final evenIn = c.nums.length - oddIn;
    final prevIn = c.nums.where(prevSet.contains).length;
    final oIdx = List<int>.generate(oddPool.length, (i) => i)..shuffle(rnd);
    final cIdx = List<int>.generate(carryPool.length, (i) => i)..shuffle(rnd);
    final oi = oIdx.where((i) => oddPool[i] >= oddIn && 6 - oddPool[i] >= evenIn).firstOrNull;
    final ci = cIdx.where((i) => carryPool[i] >= prevIn).firstOrNull;
    if (oi == null || ci == null) return null;
    return [oddPool[oi], carryPool[ci], oi, ci];
  }

  List<int>? build(_Item c, int odd, int carry, bool useDecade) {
    final oddIn = c.nums.where((x) => x.isOdd).length;
    final prevIn = c.nums.where(prevSet.contains).length;
    for (var b = 0; b < 40; b++) {
      final chosen = List<int>.of(c.nums);
      var needOdd = odd - oddIn;
      var needEven = 6 - odd - (c.nums.length - oddIn);
      var needPrev = carry - prevIn;
      var ok = true;
      while (chosen.length < 6) {
        final wantPrev = needPrev > 0;
        final cand = pool
            .where((x) =>
                !chosen.contains(x) &&
                (wantPrev ? prevSet.contains(x) : !prevSet.contains(x)) &&
                (x.isOdd ? needOdd > 0 : needEven > 0))
            .toList();
        final pk = _pick<int>(cand, (x) => numW[x], rnd); // V2 번호 비중 60/30/10
        if (pk == null) {
          ok = false;
          break;
        }
        chosen.add(pk);
        if (pk.isOdd) {
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
      return chosen;
    }
    return null;
  }

  for (final k in sizes) {
    EngineGame? gm;
    for (var t = 0; t < 60 && gm == null; t++) {
      final list = k == 4 ? quads : k == 3 ? triples : pairs;
      // 3·4개 조합은 20게임 안에서 한 번씩만 (13번 겹침 ≤2 조건)
      final cands = k == 2 ? list : list.where((x) => !usedCombo.contains(_k(x.nums))).toList();
      final c = _pick<_Item>(cands.isNotEmpty ? cands : pairs, (x) => x.p, rnd);
      if (c == null) break;
      final spec = takeSpec(c);
      if (spec == null) continue;
      final nums = build(c, spec[0], spec[1], t < 40); // 40번 시도 뒤에는 번호대 확률 완화
      if (nums != null) {
        oddPool.removeAt(spec[2]);
        carryPool.removeAt(spec[3]);
        usedCombo.add(_k(c.nums));
        gm = EngineGame(nums, EngineCombo(c.nums, c.count, c.since, c.since > c.avg, c.p));
      }
    }
    // 안전장치: 제외·필터는 유지하고 무작위
    for (var t = 0; t < 5000 && gm == null; t++) {
      final s = (List<int>.of(pool)..shuffle(rnd)).take(6).toList()..sort();
      if (valid(s)) gm = EngineGame(s, null, fallback: true);
    }
    if (gm != null) games.add(gm);
  }
  return games;
}
