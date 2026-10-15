import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lottopick/lotto_home_page.dart';
import 'package:lottopick/lotto_stats.dart';

void main() {
  test('번호대별 공 색상', () {
    expect(ballColor(1), const Color(0xFFE8A10D));
    expect(ballColor(15), const Color(0xFF1061C9));
    expect(ballColor(25), const Color(0xFFD93A4C));
    expect(ballColor(35), const Color(0xFF6E7787));
    expect(ballColor(45), const Color(0xFF2F9E44));
  });

  test('번호 생성: 방식마다 1~45 서로 다른 6개, 오름차순', () {
    for (final m in genMethods) {
      for (var i = 0; i < 200; i++) {
        final s = generateNumbers(m.key, const []);
        expect(s.length, 6);
        expect(s.toSet().length, 6);
        expect(s.every((n) => n >= 1 && n <= 45), isTrue);
        expect(s, [...s]..sort());
      }
    }
  });
}
