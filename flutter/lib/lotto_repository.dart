// Supabase lotto 스키마 읽기 전용 저장소
import 'package:supabase_flutter/supabase_flutter.dart';

class Draw {
  final int round;
  final DateTime drawDate;
  final List<int> numbers;
  final int bonus;

  Draw.fromJson(Map<String, dynamic> j)
      : round = j['round'] as int,
        drawDate = DateTime.parse(j['draw_date'] as String),
        numbers = [j['n1'], j['n2'], j['n3'], j['n4'], j['n5'], j['n6']].cast<int>(),
        bonus = j['bonus'] as int;
}

class Pick {
  final int id;
  final int targetRound;
  final List<int> numbers;
  final String method;
  final int? matchedCount;
  final bool? bonusMatched;
  final int? prizeRank;

  bool get checked => matchedCount != null;

  Pick.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        targetRound = j['target_round'] as int,
        numbers = [j['n1'], j['n2'], j['n3'], j['n4'], j['n5'], j['n6']].cast<int>(),
        method = (j['method'] ?? '') as String,
        matchedCount = j['matched_count'] as int?,
        bonusMatched = j['bonus_matched'] as bool?,
        prizeRank = j['prize_rank'] as int?;
}

class LottoRepository {
  SupabaseQuerySchema get _db => Supabase.instance.client.schema('lotto');

  /// 최신 당첨번호
  Future<Draw?> latestDraw() async {
    final row = await _db
        .from('draws')
        .select()
        .order('round', ascending: false)
        .limit(1)
        .maybeSingle();
    return row == null ? null : Draw.fromJson(row);
  }

  /// 특정 회차 당첨번호
  Future<Draw?> draw(int round) async {
    final row = await _db.from('draws').select().eq('round', round).maybeSingle();
    return row == null ? null : Draw.fromJson(row);
  }

  /// 최근 당첨번호 목록
  Future<List<Draw>> recentDraws({int limit = 20}) async {
    final rows = await _db
        .from('draws')
        .select()
        .order('round', ascending: false)
        .limit(limit);
    return rows.map(Draw.fromJson).toList();
  }

  /// 특정 회차 추출번호
  Future<List<Pick>> picks(int targetRound) async {
    final rows = await _db
        .from('picks')
        .select()
        .eq('target_round', targetRound)
        .order('method')
        .order('id');
    return rows.map(Pick.fromJson).toList();
  }
}
