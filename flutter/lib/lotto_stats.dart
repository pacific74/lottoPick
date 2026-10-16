// 당첨번호 통계 + 번호 생성 로직 (화면과 분리된 순수 계산)
import 'dart:math';

import 'lotto_repository.dart';

// ---------------------------------------------------------------- 통계

class Combo {
  final List<int> numbers;
  final int firstRound;
  final DateTime firstDate;
  int count;
  int lastRound;
  DateTime lastDate;
  Combo(this.numbers, this.count, this.lastRound, this.lastDate)
      : firstRound = lastRound,
        firstDate = lastDate;

  /// 평균 출현 간격(회). 1번만 나왔으면 null
  double? get avgRounds => count < 2 ? null : (lastRound - firstRound) / (count - 1);

  /// 평균 출현 간격(일). 1번만 나왔으면 null
  double? get avgDays => count < 2 ? null : lastDate.difference(firstDate).inDays / (count - 1);
}

class LottoStats {
  /// 번호별 출현 횟수. 결과[n] = n번 횟수 (0번 칸은 사용 안 함)
  static List<int> counts(Iterable<Draw> draws, {required bool includeBonus}) {
    final c = List<int>.filled(46, 0);
    for (final d in draws) {
      for (final n in d.numbers) {
        c[n]++;
      }
      if (includeBonus) c[d.bonus]++;
    }
    return c;
  }

  /// 1~45 를 출현 횟수로 정렬 (most=true 면 많은 순). 같으면 번호 작은 순.
  static List<int> ranked(List<int> counts, {required bool most}) {
    final nums = List<int>.generate(45, (i) => i + 1);
    nums.sort((a, b) {
      final diff = most ? counts[b] - counts[a] : counts[a] - counts[b];
      return diff != 0 ? diff : a - b;
    });
    return nums;
  }

  /// 함께 나온 번호 조합(size 개) 통계. 많이 나온 순, 같으면 최근 출현 순.
  static List<Combo> combos(Iterable<Draw> draws, int size) {
    final map = <String, Combo>{};
    for (final d in draws) {
      for (final c in _combinations(d.numbers, size)) {
        final key = c.join(',');
        final e = map[key];
        if (e == null) {
          map[key] = Combo(c, 1, d.round, d.drawDate);
        } else {
          e.count++;
          if (d.round > e.lastRound) {
            e.lastRound = d.round;
            e.lastDate = d.drawDate;
          }
        }
      }
    }
    final list = map.values.toList();
    list.sort((a, b) {
      final diff = b.count - a.count;
      return diff != 0 ? diff : b.lastRound - a.lastRound;
    });
    return list;
  }

  static List<List<int>> _combinations(List<int> src, int k) {
    final s = [...src]..sort();
    final out = <List<int>>[];
    void rec(int start, List<int> cur) {
      if (cur.length == k) {
        out.add(List<int>.of(cur));
        return;
      }
      for (var i = start; i < s.length; i++) {
        cur.add(s[i]);
        rec(i + 1, cur);
        cur.removeLast();
      }
    }

    rec(0, <int>[]);
    return out;
  }
}

// ---------------------------------------------------------------- 번호 생성
// 서버 배치(batch/lib.mjs)와 같은 4가지 방식.
// 로또는 매 회 독립 추첨이라 어떤 방식도 당첨 확률을 높이진 않음 — 방식별 성적 비교용.

class GenMethod {
  final String key;
  final String label;
  final String desc;
  const GenMethod(this.key, this.label, this.desc);
}

const genMethods = <GenMethod>[
  GenMethod('random', '랜덤', '완전 무작위로 6개를 뽑습니다'),
  GenMethod('hot', '많이 나온 번호', '최근 100회 자주 나온 번호일수록 잘 뽑힙니다'),
  GenMethod('cold', '안 나온 번호', '오래 안 나온 번호일수록 잘 뽑힙니다'),
  GenMethod('balanced', '균형', '홀짝 2~4개, 합계 100~175, 3연속 번호 제외'),
];

String methodLabel(String key) =>
    genMethods.firstWhere((m) => m.key == key, orElse: () => GenMethod(key, key, '')).label;

final _rng = Random.secure();

List<int> _pickWeighted(List<double> w, int count) {
  final chosen = <int>{};
  while (chosen.length < count) {
    var total = 0.0;
    for (var n = 1; n <= 45; n++) {
      if (!chosen.contains(n)) total += w[n];
    }
    var r = _rng.nextDouble() * total;
    for (var n = 1; n <= 45; n++) {
      if (chosen.contains(n)) continue;
      r -= w[n];
      if (r < 0) {
        chosen.add(n);
        break;
      }
    }
    if (chosen.length < count && r >= 0) {
      // 부동소수 오차로 못 뽑은 경우: 남은 번호 중 마지막 것
      for (var n = 45; n >= 1; n--) {
        if (!chosen.contains(n)) {
          chosen.add(n);
          break;
        }
      }
    }
  }
  return chosen.toList()..sort();
}

List<double> _flat() => List<double>.generate(46, (i) => i == 0 ? 0 : 1);

/// historyDesc: 최신 회차가 앞에 오는 당첨번호 목록
List<int> generateNumbers(String method, List<Draw> historyDesc) {
  switch (method) {
    case 'hot':
      final w = _flat();
      for (final d in historyDesc.take(100)) {
        for (final n in d.numbers) {
          w[n] += 1;
        }
      }
      return _pickWeighted(w, 6);
    case 'cold':
      final lastSeen = List<int>.filled(46, historyDesc.length);
      for (var i = 0; i < historyDesc.length; i++) {
        for (final n in historyDesc[i].numbers) {
          if (lastSeen[n] > i) lastSeen[n] = i;
        }
      }
      final w = _flat();
      for (var n = 1; n <= 45; n++) {
        w[n] = 1.0 + lastSeen[n];
      }
      return _pickWeighted(w, 6);
    case 'balanced':
      for (var t = 0; t < 10000; t++) {
        final s = _pickWeighted(_flat(), 6);
        final odd = s.where((n) => n.isOdd).length;
        final sum = s.reduce((a, b) => a + b);
        var run = 1, maxRun = 1;
        for (var k = 1; k < 6; k++) {
          run = s[k] == s[k - 1] + 1 ? run + 1 : 1;
          if (run > maxRun) maxRun = run;
        }
        if (odd >= 2 && odd <= 4 && sum >= 100 && sum <= 175 && maxRun < 3) return s;
      }
      return _pickWeighted(_flat(), 6);
    case 'random':
    default:
      return _pickWeighted(_flat(), 6);
  }
}
