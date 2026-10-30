import 'package:flutter/material.dart';

import 'screens/home_page.dart';

void main() {
  runApp(const NearbyInstaApp());
}

class NearbyInstaApp extends StatelessWidget {
  const NearbyInstaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '近くのスポット',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFFDD2A7B),
        // Windows で日本語が中華フォントの字形にならないよう、日本語フォントを優先する。
        fontFamily: 'Segoe UI',
        fontFamilyFallback: const ['Yu Gothic UI', 'Meiryo'],
      ),
      home: const HomePage(),
    );
  }
}
