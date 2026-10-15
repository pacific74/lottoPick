// Supabase lotto 스키마 접근
import 'package:supabase_flutter/supabase_flutter.dart';

class Draw {
  final int round;
  final DateTime drawDate;
  final List<int> numbers;
  final int bonus;

  Draw.fromJson(Map<String, dynamic> j)
      : round = j['round'] as int,
        drawDate = DateTime.parse(j['draw_date'] as String),
        numbers = ([j['n1'], j['n2'], j['n3'], j['n4'], j['n5'], j['n6']].cast<int>())..sort(),
        bonus = j['bonus'] as int;
}

class Pick {
  final int id;
  final int targetRound;
  final List<int> numbers;
  final String method;
  final String source; // 'batch' | 'app'
  final int? matchedCount;
  final bool? bonusMatched;
  final int? prizeRank;
  final bool saved; // 서버 저장 성공 여부 (저장 실패한 번호도 화면엔 보여줌)

  bool get checked => matchedCount != null;

  Pick.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        targetRound = j['target_round'] as int,
        numbers = [j['n1'], j['n2'], j['n3'], j['n4'], j['n5'], j['n6']].cast<int>(),
        method = (j['method'] ?? '') as String,
        source = (j['source'] ?? 'batch') as String,
        matchedCount = j['matched_count'] as int?,
        bonusMatched = j['bonus_matched'] as bool?,
        prizeRank = j['prize_rank'] as int?,
        saved = true;

  Pick.local(this.targetRound, this.numbers, this.method)
      : id = -1,
        source = 'app',
        matchedCount = null,
        bonusMatched = null,
        prizeRank = null,
        saved = false;
}

class LottoRepository {
  SupabaseQuerySchema get _db => Supabase.instance.client.schema('lotto');

  /// 전체 당첨번호 (회차 오름차순). Data API 가 한 번에 1000행까지라 나눠서 받음.
  Future<List<Draw>> allDraws() async {
    const page = 1000;
    final out = <Draw>[];
    for (var from = 0;; from += page) {
      final rows = await _db
          .from('draws')
          .select()
          .order('round', ascending: true)
          .range(from, from + page - 1);
      out.addAll(rows.map(Draw.fromJson));
      if (rows.length < page) break;
    }
    return out;
  }

  /// 특정 회차 추출번호. source 를 주면 그 출처만. 최근 생성한 것이 위로.
  Future<List<Pick>> picks(int targetRound, {String? source, int limit = 200}) async {
    var q = _db.from('picks').select().eq('target_round', targetRound);
    if (source != null) q = q.eq('source', source);
    final rows = await q.order('id', ascending: false).limit(limit);
    return rows.map(Pick.fromJson).toList();
  }

  /// 앱에서 생성한 번호 1세트 저장 (서버 함수 lotto.add_pick)
  Future<Pick> addPick(List<int> numbers, String method) async {
    final row = await _db.rpc('add_pick', params: {
      'p_numbers': numbers,
      'p_method': method,
    });
    return Pick.fromJson(Map<String, dynamic>.from(row as Map));
  }
}
