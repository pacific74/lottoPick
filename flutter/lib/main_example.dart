// main.dart 예시 — 기존 main.dart에 Supabase.initialize 부분과 home 만 옮겨 넣으면 됩니다.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'lotto_home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: 'https://xxxxxxxx.supabase.co',     // Supabase > Connect 에서 복사
    anonKey: '여기에_anon_public_키',          // anon(public) 키만! service_role 금지
  );
  runApp(const LottoPickApp());
}

class LottoPickApp extends StatelessWidget {
  const LottoPickApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '로또픽',
        theme: ThemeData(colorSchemeSeed: const Color(0xFF0C52D6), useMaterial3: true),
        home: const LottoHomePage(),
      );
}
