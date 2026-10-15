// 메인 화면: 최신 당첨번호 / 다음 회차 추출번호 / 지난 회차 결과
import 'package:flutter/material.dart';
import 'lotto_repository.dart';

class LottoHomePage extends StatefulWidget {
  const LottoHomePage({super.key});

  @override
  State<LottoHomePage> createState() => _LottoHomePageState();
}

class _HomeData {
  final Draw? latest;
  final List<Pick> nextPicks;
  final List<Pick> lastPicks;
  _HomeData(this.latest, this.nextPicks, this.lastPicks);
}

class _LottoHomePageState extends State<LottoHomePage> {
  final repo = LottoRepository();
  late Future<_HomeData> _future = _load();

  Future<_HomeData> _load() async {
    final latest = await repo.latestDraw();
    if (latest == null) return _HomeData(null, [], []);
    final results = await Future.wait([
      repo.picks(latest.round + 1),
      repo.picks(latest.round),
    ]);
    return _HomeData(latest, results[0], results[1]);
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('로또픽')),
      body: FutureBuilder<_HomeData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('불러오기 실패\n${snap.error}', textAlign: TextAlign.center));
          }
          final d = snap.data!;
          if (d.latest == null) {
            return const Center(child: Text('아직 당첨번호 데이터가 없습니다'));
          }
          final latest = d.latest!;
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _SectionTitle('${latest.round}회 당첨번호 (${_date(latest.drawDate)})'),
                _BallRow(numbers: latest.numbers, bonus: latest.bonus),
                const SizedBox(height: 28),
                _SectionTitle('${latest.round + 1}회 추출번호'),
                if (d.nextPicks.isEmpty) const Text('아직 추출 전입니다'),
                ...d.nextPicks.map((p) => _PickTile(pick: p)),
                const SizedBox(height: 28),
                _SectionTitle('${latest.round}회 추출번호 결과'),
                if (d.lastPicks.isEmpty) const Text('이 회차에 추출한 번호가 없습니다'),
                ...d.lastPicks.map((p) => _PickTile(pick: p, draw: latest)),
              ],
            ),
          );
        },
      ),
    );
  }

  String _date(DateTime t) =>
      '${t.year}.${t.month.toString().padLeft(2, '0')}.${t.day.toString().padLeft(2, '0')}';
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
      );
}

/// 동행복권 색 구분: 1-10 노랑, 11-20 파랑, 21-30 빨강, 31-40 회색, 41-45 초록
Color ballColor(int n) {
  if (n <= 10) return const Color(0xFFFBC400);
  if (n <= 20) return const Color(0xFF69C8F2);
  if (n <= 30) return const Color(0xFFFF7272);
  if (n <= 40) return const Color(0xFFAAAAAA);
  return const Color(0xFFB0D840);
}

class Ball extends StatelessWidget {
  final int n;
  final bool dim;
  final double size;
  const Ball(this.n, {super.key, this.dim = false, this.size = 36});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: dim ? Colors.grey.shade300 : ballColor(n),
          shape: BoxShape.circle,
        ),
        child: Text('$n',
            style: TextStyle(
                color: dim ? Colors.grey.shade600 : Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: size * 0.4)),
      );
}

class _BallRow extends StatelessWidget {
  final List<int> numbers;
  final int bonus;
  const _BallRow({required this.numbers, required this.bonus});
  @override
  Widget build(BuildContext context) => Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ...numbers.map((n) => Ball(n)),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Text('+')),
          Ball(bonus),
        ],
      );
}

class _PickTile extends StatelessWidget {
  final Pick pick;
  final Draw? draw; // 있으면 맞힌 번호만 색칠
  const _PickTile({required this.pick, this.draw});

  @override
  Widget build(BuildContext context) {
    final win = draw?.numbers.toSet();
    String? result;
    if (pick.checked) {
      result = pick.prizeRank != null ? '${pick.prizeRank}등' : '${pick.matchedCount}개';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 64, child: Text(pick.method, style: const TextStyle(fontSize: 12))),
          ...pick.numbers.map((n) => Ball(n, size: 30, dim: win != null && !win.contains(n))),
          const Spacer(),
          if (result != null)
            Text(result,
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: pick.prizeRank != null ? Colors.red : Colors.grey)),
        ],
      ),
    );
  }
}
