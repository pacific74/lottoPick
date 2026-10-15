import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'lotto_home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  runApp(const LottoPickApp());
}

class LottoPickApp extends StatelessWidget {
  const LottoPickApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '로또픽',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF0C52D6),
        useMaterial3: true,
      ),
      home: const LottoHomePage(),
    );
  }
}
