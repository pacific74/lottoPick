// 메인 화면: 최신 당첨번호 / 다음 회차 번호 생성 / 당첨번호 통계 / 지난 회차 결과
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'lotto_repository.dart';
import 'lotto_stats.dart';
import 'update_service.dart';

class LottoHomePage extends StatefulWidget {
  const LottoHomePage({super.key});

  @override
  State<LottoHomePage> createState() => _LottoHomePageState();
}

class _LottoHomePageState extends State<LottoHomePage> with WidgetsBindingObserver {
  final repo = LottoRepository();

  bool _loading = true;
  Object? _error;
  List<Draw> _draws = []; // 회차 오름차순
  List<Pick> _appPicks = []; // 다음 회차, 앱에서 생성한 번호
  List<Pick> _lastPicks = []; // 최신 회차 추출번호 (채점 결과)

  // 번호 생성
  String _method = 'random';
  int _setCount = 1;
  bool _generating = false;

  // 통계 조건 (입력 중)
  int _weeks = 0; // 0 = 전체, -1 = 직접 지정
  int _from = 1;
  int _to = 1;
  bool _bonus = false;
  // 통계 조건 (조회 적용됨)
  int _aFrom = 1;
  int _aTo = 1;
  bool _aBonus = false;
  // 통계 결과
  List<int> _counts = List<int>.filled(46, 0);
  bool _sortByCount = false;
  int _comboSize = 2;
  List<Combo> _combos = [];
  int _comboShown = 10;
  final Set<String> _openCombos = {}; // 펼쳐서 회차 목록을 보는 조합

  String _version = '';

  Draw get _latest => _draws.last;
  int get _nextRound => _latest.round + 1;

  @override
  void initState() {
    super.initState();
    _load();
    UpdateService.currentLabel().then((v) {
      if (mounted) setState(() => _version = v);
    }).catchError((_) {});
    // 앱 시작 직후 새 버전 확인
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkUpdate());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // 백그라운드에 있다가 다시 앱으로 돌아왔을 때도 확인 (10분에 한 번까지)
  DateTime? _lastUpdateCheck;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkUpdate();
  }

  void _checkUpdate() {
    final now = DateTime.now();
    if (_lastUpdateCheck != null && now.difference(_lastUpdateCheck!) < const Duration(minutes: 10)) return;
    _lastUpdateCheck = now;
    if (mounted) UpdateService.check(context);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final draws = await repo.allDraws();
      List<Pick> app = [], last = [];
      if (draws.isNotEmpty) {
        final r = draws.last.round;
        final res = await Future.wait([
          repo.picks(r + 1, source: 'app', limit: 50),
          repo.picks(r),
        ]);
        app = res[0];
        last = res[1];
      }
      if (!mounted) return;
      setState(() {
        _draws = draws;
        _appPicks = app;
        _lastPicks = last;
        if (draws.isNotEmpty) {
          _setPreset(_weeks == -1 ? 0 : _weeks);
          _apply();
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  // ------------------------------------------------------------ 통계 조건

  void _setPreset(int weeks) {
    _weeks = weeks;
    _to = _latest.round;
    _from = weeks == 0 ? 1 : max(1, _latest.round - weeks + 1);
  }

  void _apply() {
    _aFrom = min(_from, _to);
    _aTo = max(_from, _to);
    _aBonus = _bonus;
    final sel = _draws.where((d) => d.round >= _aFrom && d.round <= _aTo).toList();
    _counts = LottoStats.counts(sel, includeBonus: _aBonus);
    _combos = LottoStats.combos(sel, _comboSize);
    _comboShown = 10;
  }

  void _changeComboSize(int size) {
    setState(() {
      _comboSize = size;
      final sel = _draws.where((d) => d.round >= _aFrom && d.round <= _aTo);
      _combos = LottoStats.combos(sel, size);
      _comboShown = 10;
    });
  }

  // ------------------------------------------------------------ 번호 생성

  Future<void> _generate() async {
    setState(() => _generating = true);
    final historyDesc = _draws.reversed.toList();
    final made = <Pick>[];
    String? err;
    for (var i = 0; i < _setCount; i++) {
      final nums = generateNumbers(_method, historyDesc);
      try {
        made.add(await repo.addPick(nums, _method));
      } catch (e) {
        err = '$e';
        made.add(Pick.local(_nextRound, nums, _method));
      }
    }
    if (!mounted) return;
    setState(() {
      _appPicks = [...made.reversed, ..._appPicks];
      _generating = false;
    });
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('번호는 만들었지만 저장하지 못했습니다\n$err')),
      );
    }
  }

  // ------------------------------------------------------------ 화면

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('로또픽', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          if (kIsWeb)
            IconButton(
              tooltip: '안드로이드 앱 받기',
              onPressed: _openDownload,
              icon: const Icon(Icons.android),
            ),
          IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'update') {
                if (kIsWeb) {
                  _openDownload();
                } else {
                  UpdateService.check(context, manual: true);
                }
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'update', child: Text(kIsWeb ? '안드로이드 앱 받기' : '업데이트 확인')),
              PopupMenuItem(enabled: false, child: Text('현재 버전 $_version')),
            ],
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('불러오기 실패\n$_error', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('다시 시도')),
          ]),
        ),
      );
    }
    if (_draws.isEmpty) return const Center(child: Text('아직 당첨번호 데이터가 없습니다'));

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        // 넓은 화면(웹/태블릿)에서는 가운데 최대 720px 폭으로
        padding: EdgeInsets.fromLTRB(
          max(12.0, (MediaQuery.sizeOf(context).width - 720) / 2),
          4,
          max(12.0, (MediaQuery.sizeOf(context).width - 720) / 2),
          32,
        ),
        children: [
          if (kIsWeb) _webAppBanner(),
          _latestCard(),
          _generateCard(),
          _filterCard(),
          _rankCard(most: true),
          _rankCard(most: false),
          _allNumbersCard(),
          _comboCard(),
          _lastPicksCard(),
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Text(
              _version.isEmpty ? '로또픽' : '로또픽 $_version',
              textAlign: TextAlign.center,
              style: _subStyle(context),
            ),
          ),
        ],
      ),
    );
  }

  // 웹에서만: 안드로이드 앱 다운로드 안내
  Future<void> _openDownload() async {
    await launchUrl(Uri.parse('${updateBaseUrl}download.html'), webOnlyWindowName: '_self');
  }

  Widget _webAppBanner() {
    return Card(
      margin: const EdgeInsets.only(top: 12),
      color: Theme.of(context).colorScheme.primaryContainer,
      child: ListTile(
        leading: const Icon(Icons.android),
        title: const Text('안드로이드 앱으로 보기'),
        subtitle: const Text('설치하면 새 버전이 나올 때 자동으로 알려줍니다'),
        trailing: const Icon(Icons.download),
        onTap: _openDownload,
      ),
    );
  }

  Widget _latestCard() {
    final d = _latest;
    return _Section(
      title: '${d.round}회 당첨결과',
      trailing: Text(_ymd(d.drawDate), style: _subStyle(context)),
      child: Center(child: _BallRow(numbers: d.numbers, bonus: d.bonus)),
    );
  }

  Widget _generateCard() {
    final m = genMethods.firstWhere((x) => x.key == _method);
    return _Section(
      title: '$_nextRound회 번호 생성',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 6, runSpacing: 4, children: [
          for (final g in genMethods)
            ChoiceChip(
              label: Text(g.label),
              selected: _method == g.key,
              onSelected: (_) => setState(() => _method = g.key),
            ),
        ]),
        const SizedBox(height: 6),
        Text(m.desc, style: _subStyle(context)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('1세트')),
                ButtonSegment(value: 3, label: Text('3세트')),
                ButtonSegment(value: 5, label: Text('5세트')),
              ],
              selected: {_setCount},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _setCount = s.first),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: _generating ? null : _generate,
          icon: _generating
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.casino_outlined),
          label: const Text('다음 회차 번호 생성'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
        if (_appPicks.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('생성한 번호 (${_appPicks.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          for (final p in _appPicks.take(20)) _PickTile(pick: p),
        ],
      ]),
    );
  }

  Widget _filterCard() {
    final rounds = List<int>.generate(_latest.round, (i) => _latest.round - i);
    DropdownButton<int> roundBox(int value, ValueChanged<int> onChanged) => DropdownButton<int>(
          value: value,
          isDense: true,
          menuMaxHeight: 320,
          items: [for (final r in rounds) DropdownMenuItem(value: r, child: Text('$r회'))],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        );

    return _Section(
      title: '당첨번호 통계',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('최근주간', style: _subStyle(context)),
        const SizedBox(height: 4),
        Wrap(spacing: 6, runSpacing: 4, children: [
          for (final w in const [4, 8, 12, 52, 0])
            ChoiceChip(
              label: Text(w == 0 ? '전체' : '$w주'),
              selected: _weeks == w,
              onSelected: (_) => setState(() => _setPreset(w)),
            ),
        ]),
        const SizedBox(height: 10),
        Text('구간 지정', style: _subStyle(context)),
        Row(children: [
          roundBox(_from, (v) => setState(() {
                _from = v;
                _weeks = -1;
              })),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('~')),
          roundBox(_to, (v) => setState(() {
                _to = v;
                _weeks = -1;
              })),
          const Spacer(),
          const Text('보너스 포함'),
          Checkbox(value: _bonus, onChanged: (v) => setState(() => _bonus = v ?? false)),
        ]),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: () => setState(_apply),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
          child: const Text('조회'),
        ),
        const SizedBox(height: 8),
        Text(
          '제 $_aFrom회 ~ 제 $_aTo회 (${_aTo - _aFrom + 1}회) 기준${_aBonus ? ' · 보너스 포함' : ''}',
          style: _subStyle(context),
          textAlign: TextAlign.center,
        ),
      ]),
    );
  }

  Widget _rankCard({required bool most}) {
    final nums = LottoStats.ranked(_counts, most: most).take(6).toList();
    return _Section(
      title: most ? '가장 많이 추첨된 번호 6개' : '가장 적게 추첨된 번호 6개',
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [for (final n in nums) _CountBall(n: n, count: _counts[n])],
      ),
    );
  }

  Widget _allNumbersCard() {
    final nums = _sortByCount
        ? LottoStats.ranked(_counts, most: true)
        : List<int>.generate(45, (i) => i + 1);
    return _Section(
      title: '추첨번호 전체 통계',
      trailing: SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: false, label: Text('번호순')),
          ButtonSegment(value: true, label: Text('당첨순')),
        ],
        selected: {_sortByCount},
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        onSelectionChanged: (s) => setState(() => _sortByCount = s.first),
      ),
      child: LayoutBuilder(
        builder: (context, box) => GridView.count(
          crossAxisCount: box.maxWidth >= 520 ? 10 : 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 6,
          // 칸 높이 = 공(30) + 글자(약 16) + 여백
          childAspectRatio: (box.maxWidth / (box.maxWidth >= 520 ? 10 : 7)) / 52,
          children: [for (final n in nums) _CountBall(n: n, count: _counts[n], size: 30)],
        ),
      ),
    );
  }

  Widget _comboCard() {
    final shown = _combos.take(_comboShown).toList();
    return _Section(
      title: '동반 출현 번호 통계',
      trailing: SegmentedButton<int>(
        segments: const [
          ButtonSegment(value: 2, label: Text('2개')),
          ButtonSegment(value: 3, label: Text('3개')),
          ButtonSegment(value: 4, label: Text('4개')),
        ],
        selected: {_comboSize},
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        onSelectionChanged: (s) => _changeComboSize(s.first),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (shown.isEmpty) const Text('데이터가 없습니다'),
        for (final c in shown) _comboTile(c),
        if (_combos.length > _comboShown)
          TextButton(
            onPressed: () => setState(() => _comboShown += 10),
            child: Text('더 보기 ($_comboShown/${_combos.length})'),
          ),
      ]),
    );
  }

  Widget _comboTile(Combo c) {
    final key = c.numbers.join(',');
    final open = _openCombos.contains(key);
    final since = _aTo - c.lastRound; // 마지막 출현 후 지난 회차 수
    final gapText = c.avgGap == null
        ? '1번만 출현'
        : '평균 ${c.avgGap!.toStringAsFixed(1)}회마다 (최소 ${c.minGap} · 최대 ${c.maxGap})';
    return InkWell(
      onTap: () => setState(() => open ? _openCombos.remove(key) : _openCombos.add(key)),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text('${c.count}회', style: const TextStyle(fontWeight: FontWeight.bold)),
                  Icon(open ? Icons.expand_less : Icons.expand_more, size: 18),
                ]),
                Text('최근출현 ${_ymd(c.lastDate)} (${c.lastRound}회차) · $since회 지남', style: _subStyle(context)),
                Text(gapText, style: _subStyle(context)),
              ]),
            ),
            for (final n in c.numbers) Ball(n, size: 30),
          ]),
          if (open) ...[
            const SizedBox(height: 6),
            Text('출현 회차', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            Text(c.rounds.join(', '), style: const TextStyle(fontSize: 12)),
            if (c.gaps.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('회차 간격', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              Text(c.gaps.join(', '), style: const TextStyle(fontSize: 12)),
            ],
          ],
        ]),
      ),
    );
  }

  Widget _lastPicksCard() {
    final d = _latest;
    return _Section(
      title: '${d.round}회 추출번호 결과',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_lastPicks.isEmpty) const Text('이 회차에 추출한 번호가 없습니다'),
        for (final p in _lastPicks) _PickTile(pick: p, draw: d),
      ]),
    );
  }

  TextStyle? _subStyle(BuildContext context) =>
      Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor);
}

String _ymd(DateTime t) =>
    '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

// ================================================================ 공통 위젯

class _Section extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final Widget child;
  const _Section({required this.title, this.trailing, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text(title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            ),
            if (trailing != null) trailing!,
          ]),
          const SizedBox(height: 10),
          child,
        ]),
      ),
    );
  }
}

/// 동행복권 색 구분: 1-10 노랑, 11-20 파랑, 21-30 빨강, 31-40 회색, 41-45 초록
Color ballColor(int n) {
  if (n <= 10) return const Color(0xFFE8A10D);
  if (n <= 20) return const Color(0xFF1061C9);
  if (n <= 30) return const Color(0xFFD93A4C);
  if (n <= 40) return const Color(0xFF6E7787);
  return const Color(0xFF2F9E44);
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
                fontSize: size * 0.42)),
      );
}

class _CountBall extends StatelessWidget {
  final int n;
  final int count;
  final double size;
  const _CountBall({required this.n, required this.count, this.size = 36});

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        Ball(n, size: size),
        const SizedBox(height: 2),
        Text('$count회', style: const TextStyle(fontSize: 11)),
      ]);
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
    } else if (!pick.saved) {
      result = '미저장';
    }
    final label = '${methodLabel(pick.method)}${pick.source == 'app' && draw != null ? '·앱' : ''}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(
          width: 72,
          child: Text(label, style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis),
        ),
        ...pick.numbers.map((n) => Ball(n, size: 28, dim: win != null && !win.contains(n))),
        const Spacer(),
        if (result != null)
          Text(result,
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: pick.prizeRank != null ? Colors.red : Colors.grey)),
      ]),
    );
  }
}
