import 'package:flutter/material.dart';

/// 暗色主题 —— 车灯 App 用深色底,灯光的发光效果才立得起来
class AppColors {
  static const bg = Color(0xFF0A0C10);
  static const surface = Color(0xFF15181F);
  static const surfaceHi = Color(0xFF1E222B);
  static const border = Color(0xFF2A2F3A);

  static const accent = Color(0xFFFF3B30); // 车身红
  static const online = Color(0xFF34D399);
  static const offline = Color(0xFF6B7280);

  static const textHi = Color(0xFFF3F5F9);
  static const textLo = Color(0xFF8A93A5);

  /// 灯光的两种真实颜色
  static const lightWhite = Color(0xFFEAF2FF);
  static const lightYellow = Color(0xFFFFB020);
}

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: AppColors.accent,
    surface: AppColors.surface,
    onSurface: AppColors.textHi,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    fontFamily: null,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: AppColors.textHi,
        fontSize: 19,
        fontWeight: FontWeight.w600,
      ),
      iconTheme: IconThemeData(color: AppColors.textHi),
    ),
    dividerColor: AppColors.border,
    sliderTheme: const SliderThemeData(
      activeTrackColor: AppColors.accent,
      inactiveTrackColor: AppColors.border,
      thumbColor: Colors.white,
      trackHeight: 4,
    ),
  );
}
