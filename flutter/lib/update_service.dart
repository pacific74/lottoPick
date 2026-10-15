// 앱 업데이트: 웹에 올라간 version.json 과 비교 → 새 빌드면 APK 받아 설치 화면 열기
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// push.bat(deploy.ps1) 이 APK 와 version.json 을 올리는 곳
const updateBaseUrl = 'https://stockeye-pacific74.vercel.app/lotto/';

class RemoteVersion {
  final String version;
  final int build;
  final String time;
  final String apk;

  RemoteVersion.fromJson(Map<String, dynamic> j)
      : version = '${j['version'] ?? ''}',
        build = int.tryParse('${j['build']}') ?? 0,
        time = '${j['time'] ?? ''}',
        apk = '${j['apk'] ?? 'lotto.apk'}';
}

class UpdateService {
  static bool _busy = false;

  /// 화면 표시용 현재 버전 "v0.0.1 (3)"
  static Future<String> currentLabel() async {
    final p = await PackageInfo.fromPlatform();
    return 'v${p.version} (${p.buildNumber})';
  }

  /// 새 버전 확인. manual=true 면 "최신 버전입니다" / 실패 메시지도 보여줌.
  static Future<void> check(BuildContext context, {bool manual = false}) async {
    if (kIsWeb || !Platform.isAndroid || _busy) return;
    _busy = true;
    try {
      final info = await PackageInfo.fromPlatform();
      final current = int.tryParse(info.buildNumber) ?? 0;
      final uri = Uri.parse('${updateBaseUrl}version.json?t=${DateTime.now().millisecondsSinceEpoch}');
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) throw 'HTTP ${res.statusCode}';
      final remote = RemoteVersion.fromJson(
          Map<String, dynamic>.from(jsonDecode(utf8.decode(res.bodyBytes)) as Map));
      if (!context.mounted) return;

      if (remote.build <= current) {
        if (manual) _snack(context, '최신 버전입니다 (v${info.version} / ${info.buildNumber})');
        return;
      }

      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('새 버전이 있습니다'),
          content: Text('현재: v${info.version} (${info.buildNumber})\n'
              '새 버전: v${remote.version} (${remote.build})\n'
              '${remote.time.isEmpty ? '' : '배포: ${remote.time}\n'}'
              '\n지금 업데이트할까요?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('나중에')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('업데이트')),
          ],
        ),
      );
      if (ok == true && context.mounted) await _downloadAndInstall(context, remote);
    } catch (e) {
      if (manual && context.mounted) _snack(context, '업데이트 확인 실패: $e');
    } finally {
      _busy = false;
    }
  }

  static Future<void> _downloadAndInstall(BuildContext context, RemoteVersion r) async {
    final progress = ValueNotifier<double?>(null);
    var dialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('새 버전 받는 중'),
          content: ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (_, v, __) => Column(mainAxisSize: MainAxisSize.min, children: [
              LinearProgressIndicator(value: v),
              const SizedBox(height: 8),
              Text(v == null ? '' : '${(v * 100).toStringAsFixed(0)}%'),
            ]),
          ),
        ),
      ),
    );
    void closeDialog() {
      if (dialogOpen && context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      dialogOpen = false;
    }

    final client = http.Client();
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/lotto_${r.build}.apk');
      final resp = await client.send(http.Request('GET', Uri.parse('$updateBaseUrl${r.apk}?v=${r.build}')));
      if (resp.statusCode != 200) throw 'HTTP ${resp.statusCode}';
      final total = resp.contentLength ?? 0;
      var received = 0;
      final sink = file.openWrite();
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) progress.value = received / total;
      }
      await sink.close();
      closeDialog();

      // 안드로이드 설치 화면 열기 (처음 한 번은 "이 출처 허용" 설정을 켜야 함)
      final result = await OpenFilex.open(file.path, type: 'application/vnd.android.package-archive');
      if (result.type != ResultType.done) throw result.message;
    } catch (e) {
      closeDialog();
      if (context.mounted) _snack(context, '업데이트 실패: $e');
    } finally {
      client.close();
      progress.dispose();
    }
  }

  static void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
