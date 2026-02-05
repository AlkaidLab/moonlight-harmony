/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

/**
 * 应用主题系统
 * 
 * 双主题配色:
 * - 深色主题: 巧克力色系 (温暖的棕色调)
 * - 浅色主题: Gura 蓝色系 (鲨鱼蓝/海蓝色)
 * 灵感来自 moonlight-vplus Android 版本
 */

/**
 * 当前主题类型
 */
export enum ThemeMode {
  DARK = 'dark',   // 巧克力深色主题
  LIGHT = 'light'  // Gura 蓝浅色主题
}

/**
 * 深色主题 - 巧克力色系
 */
export class DarkThemeColors {
  // 主色调 - 巧克力棕
  static readonly Primary = '#D7A574';           // 主色 - 奶茶棕/焦糖色
  static readonly PrimaryDark = '#B8865A';       // 深色主色
  static readonly PrimaryLight = '#E8C4A0';      // 浅色主色
  static readonly PrimaryGlow = '#D7A57440';     // 发光效果

  // 强调色 - 暖金色
  static readonly Accent = '#F5D59A';            // 暖金强调色
  static readonly AccentDark = '#D4B67A';        // 深金色
  static readonly AccentLight = '#FFE8B8';       // 浅金色

  // 背景色 - 深巧克力
  static readonly Background = '#1A1210';        // 主背景 - 深巧克力
  static readonly BackgroundDark = '#0F0A08';    // 更深背景
  static readonly BackgroundElevated = '#241C18'; // 提升背景
  static readonly Surface = '#2A2220';           // 表面色
  static readonly SurfaceDark = '#201816';       // 深表面
  static readonly SurfaceLight = '#342A26';      // 浅表面

  // 卡片背景
  static readonly CardBackground = '#2E2422';    // 卡片背景
  static readonly CardBackgroundHover = '#3A302C'; // 悬停状态
  static readonly CardBackgroundActive = '#463C38'; // 激活状态
  static readonly CardBorder = '#3A302C';        // 卡片边框

  // 文字颜色
  static readonly TextPrimary = '#F5F0EB';       // 主文字 - 暖白
  static readonly TextSecondary = '#B8A898';     // 次要文字 - 浅棕灰
  static readonly TextTertiary = '#786858';      // 第三级文字
  static readonly TextOnPrimary = '#1A1210';     // 主色上的文字
  static readonly TextGlow = '#D7A574';          // 发光文字

  // 状态颜色
  static readonly Success = '#8BC34A';           // 成功 - 抹茶绿
  static readonly Warning = '#FFB74D';           // 警告 - 琥珀橙
  static readonly Error = '#FF7043';             // 错误 - 珊瑚红
  static readonly Info = '#4FC3F7';              // 信息 - 天蓝

  // 边框和分割线
  static readonly Border = '#3A302C';            // 边框
  static readonly BorderGlow = '#D7A57460';      // 发光边框
  static readonly Divider = '#2E2422';           // 分割线

  // 在线/离线状态
  static readonly Online = '#8BC34A';            // 在线 - 抹茶绿
  static readonly Offline = '#786858';           // 离线 - 深灰
  static readonly Paired = '#D7A574';            // 已配对 - 焦糖色
  static readonly Unpaired = '#FFB74D';          // 未配对 - 琥珀

  // 特效色
  static readonly GlowPrimary = '#D7A57440';     // 主色发光
  static readonly GlowAccent = '#F5D59A40';      // 强调色发光
}

/**
 * 浅色主题 - Gura 蓝色系 (鲨鱼蓝)
 */
export class LightThemeColors {
  // 主色调 - Gura 蓝 (海蓝/鲨鱼蓝)
  static readonly Primary = '#3D8ECF';           // 主色 - Gura 蓝
  static readonly PrimaryDark = '#2D6FA8';       // 深色主色
  static readonly PrimaryLight = '#5FAEE8';      // 浅色主色
  static readonly PrimaryGlow = '#3D8ECF40';     // 发光效果

  // 强调色 - 白蓝色
  static readonly Accent = '#A8D5E8';            // 浅蓝强调色
  static readonly AccentDark = '#7BC0DB';        // 深浅蓝
  static readonly AccentLight = '#D4EDF7';       // 更浅蓝

  // 背景色 - 浅色系
  static readonly Background = '#F5F9FC';        // 主背景 - 浅蓝白
  static readonly BackgroundDark = '#E8F1F7';    // 稍深背景
  static readonly BackgroundElevated = '#FFFFFF'; // 提升背景 - 纯白
  static readonly Surface = '#FFFFFF';           // 表面色 - 白色
  static readonly SurfaceDark = '#F0F5F9';       // 深表面
  static readonly SurfaceLight = '#FFFFFF';      // 浅表面

  // 卡片背景
  static readonly CardBackground = '#FFFFFF';    // 卡片背景
  static readonly CardBackgroundHover = '#F5F9FC'; // 悬停状态
  static readonly CardBackgroundActive = '#E8F1F7'; // 激活状态
  static readonly CardBorder = '#D4E6F0';        // 卡片边框

  // 文字颜色
  static readonly TextPrimary = '#1A3A4A';       // 主文字 - 深蓝灰
  static readonly TextSecondary = '#5A7A8A';     // 次要文字 - 中蓝灰
  static readonly TextTertiary = '#8AA0AA';      // 第三级文字
  static readonly TextOnPrimary = '#FFFFFF';     // 主色上的文字
  static readonly TextGlow = '#3D8ECF';          // 发光文字

  // 状态颜色
  static readonly Success = '#4CAF50';           // 成功 - 绿色
  static readonly Warning = '#FF9800';           // 警告 - 橙色
  static readonly Error = '#F44336';             // 错误 - 红色
  static readonly Info = '#2196F3';              // 信息 - 蓝色

  // 边框和分割线
  static readonly Border = '#D4E6F0';            // 边框
  static readonly BorderGlow = '#3D8ECF60';      // 发光边框
  static readonly Divider = '#E8F1F7';           // 分割线

  // 在线/离线状态
  static readonly Online = '#4CAF50';            // 在线 - 绿色
  static readonly Offline = '#9E9E9E';           // 离线 - 灰色
  static readonly Paired = '#3D8ECF';            // 已配对 - Gura蓝
  static readonly Unpaired = '#FF9800';          // 未配对 - 橙色

  // 特效色
  static readonly GlowPrimary = '#3D8ECF40';     // 主色发光
  static readonly GlowAccent = '#A8D5E840';      // 强调色发光
}

/**
 * 当前使用的颜色 - 使用资源引用，自动跟随系统深浅色
 * 浅色模式：Gura 蓝色系
 * 深色模式：巧克力色系
 */
export class AppColors {
  // 使用资源引用实现自动深浅色切换
  
  // 主色调 - 资源引用
  static readonly Primary = $r('app.color.primary');
  static readonly PrimaryDark = $r('app.color.primary_dark');
  static readonly PrimaryLight = $r('app.color.primary_light');
  static readonly PrimaryGlow = $r('app.color.glow_primary');

  // 强调色 - 资源引用
  static readonly Accent = $r('app.color.accent');
  static readonly AccentDark = $r('app.color.accent_dark');
  static readonly AccentLight = $r('app.color.accent');

  // 背景色 - 资源引用
  static readonly Background = $r('app.color.background');
  static readonly BackgroundDark = $r('app.color.background');
  static readonly BackgroundElevated = $r('app.color.background_elevated');
  static readonly Surface = $r('app.color.surface');
  static readonly SurfaceDark = $r('app.color.surface_dark');
  static readonly SurfaceLight = $r('app.color.surface');
  static readonly SurfaceTransparent = $r('app.color.surface_transparent');

  // 卡片背景 - 资源引用
  static readonly CardBackground = $r('app.color.card_background');
  static readonly CardBackgroundHover = $r('app.color.card_background');
  static readonly CardBackgroundActive = $r('app.color.card_background');
  static readonly CardBorder = $r('app.color.card_border');

  // 文字颜色 - 资源引用
  static readonly TextPrimary = $r('app.color.text_primary');
  static readonly TextSecondary = $r('app.color.text_secondary');
  static readonly TextTertiary = $r('app.color.text_tertiary');
  static readonly TextOnPrimary = $r('app.color.text_on_primary');
  static readonly TextGlow = $r('app.color.primary');

  // 状态颜色 - 资源引用
  static readonly Success = $r('app.color.success_green');
  static readonly Warning = $r('app.color.warning_yellow');
  static readonly Error = $r('app.color.error_red');
  static readonly Info = $r('app.color.info_blue');

  // 边框和分割线 - 资源引用
  static readonly Border = $r('app.color.border');
  static readonly BorderGlow = $r('app.color.glow_primary');
  static readonly Divider = $r('app.color.divider');

  // 在线/离线状态 - 资源引用
  static readonly Online = $r('app.color.online_green');
  static readonly Offline = $r('app.color.offline_gray');
  static readonly Paired = $r('app.color.primary');
  static readonly Unpaired = $r('app.color.warning_yellow');

  // 游戏状态 - 资源引用
  static readonly Gaming = $r('app.color.error_red');
  static readonly Streaming = $r('app.color.success_green');

  // 特效色 - 资源引用
  static readonly GlowGreen = $r('app.color.glow_primary');
  static readonly GlowCyan = $r('app.color.glow_accent');
  static readonly GradientStart = $r('app.color.primary');
  static readonly GradientEnd = $r('app.color.accent');

  // 覆盖层 - 资源引用
  static readonly Overlay = $r('app.color.overlay');
  static readonly OverlayLight = '#00000060';
}

/**
 * 状态颜色字符串常量 - 用于代码逻辑中需要字符串类型的场景
 * 这些颜色会根据当前环境返回对应主题的颜色值
 */
export class StatusColors {
  // 在线状态
  static readonly OnlineLight = '#4CAF50';
  static readonly OnlineDark = '#8BC34A';
  
  // 离线状态
  static readonly OfflineLight = '#9E9E9E';
  static readonly OfflineDark = '#786858';
  
  // 已配对
  static readonly PairedLight = '#3D8ECF';
  static readonly PairedDark = '#D7A574';
  
  // 未配对
  static readonly UnpairedLight = '#FF9800';
  static readonly UnpairedDark = '#FFB74D';
  
  // 游戏中
  static readonly GamingLight = '#F44336';
  static readonly GamingDark = '#FF7043';
}

/**
 * 尺寸定义
 */
export class AppSizes {
  // 图标尺寸
  static readonly IconSmall = 16;
  static readonly IconMedium = 24;
  static readonly IconLarge = 32;
  static readonly IconXLarge = 48;
  
  // 头像/Logo 尺寸
  static readonly AvatarSmall = 32;
  static readonly AvatarMedium = 48;
  static readonly AvatarLarge = 64;
  static readonly AvatarXLarge = 80;
  
  // 按钮高度
  static readonly ButtonSmall = 32;
  static readonly ButtonMedium = 44;
  static readonly ButtonLarge = 56;
  
  // 圆角
  static readonly RadiusSmall = 4;
  static readonly RadiusMedium = 8;
  static readonly RadiusLarge = 12;
  static readonly RadiusXLarge = 16;
  static readonly RadiusFull = 9999;
  
  // 字体大小
  static readonly FontCaption = 12;
  static readonly FontBody = 14;
  static readonly FontSubtitle = 16;
  static readonly FontTitle = 18;
  static readonly FontHeadline = 20;
  static readonly FontLargeTitle = 24;
}

/**
 * 间距定义
 */
export class AppSpacing {
  static readonly XSmall = 4;
  static readonly Small = 8;
  static readonly Medium = 12;
  static readonly Large = 16;
  static readonly XLarge = 24;
  static readonly XXLarge = 32;
  static readonly XXXLarge = 48;
}

/**
 * 动画配置
 */
export class AppAnimation {
  // 动画时长 (毫秒)
  static readonly Fast = 150;
  static readonly Normal = 250;
  static readonly Slow = 350;
  
  // 缓动曲线
  static readonly EaseIn = Curve.EaseIn;
  static readonly EaseOut = Curve.EaseOut;
  static readonly EaseInOut = Curve.EaseInOut;
  static readonly Spring = Curve.FastOutSlowIn;
}

/**
 * 阴影定义 - 巧克力主题发光效果
 */
export class AppShadows {
  static readonly Small: ShadowOptions = {
    radius: 4,
    color: '#D7A57420',
    offsetX: 0,
    offsetY: 2
  };

  static readonly Medium: ShadowOptions = {
    radius: 8,
    color: '#D7A57430',
    offsetX: 0,
    offsetY: 4
  };

  static readonly Large: ShadowOptions = {
    radius: 16,
    color: '#D7A57440',
    offsetX: 0,
    offsetY: 8
  };

  // 主色发光效果
  static readonly GlowGreen: ShadowOptions = {
    radius: 20,
    color: '#D7A57460',
    offsetX: 0,
    offsetY: 0
  };

  // 强调色发光效果
  static readonly GlowCyan: ShadowOptions = {
    radius: 20,
    color: '#F5D59A60',
    offsetX: 0,
    offsetY: 0
  };
}
