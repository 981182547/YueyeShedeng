/// 中英文案表。
///
/// 没有用 intl / .arb 那一套:全 App 七十来条文案,官方方案要装依赖、跑代码生成,
/// 还得配 delegate,对这个体量是杀鸡用牛刀。这里直接用 getter + 三元,
/// 加一条文案就是加一行,改语言只要重建界面,没有任何生成步骤。
///
/// 用法:界面层从 AppState 拿 —— `state.s.connected`;
/// BleManager 那种拿不到 state 的地方,注入一个 `S Function()` 回调,
/// 这样切换语言之后新产生的提示也会跟着变。
library;

enum AppLang { zh, en }

class S {
  final AppLang lang;
  const S(this.lang);

  bool get zh => lang == AppLang.zh;

  // ── 通用 ──────────────────────────────────────────
  String get appTitle => 'SPOTLIGHT'; // 品牌名，两种语言都不翻
  String get on => zh ? '开' : 'On';
  String get off => zh ? '关' : 'Off';
  String get allOn => zh ? '全开' : 'All On';
  String get allOff => zh ? '全关' : 'All Off';
  String get cancel => zh ? '取消' : 'Cancel';

  // ── 连接状态 ──────────────────────────────────────
  String get connected => zh ? '已连接' : 'Connected';
  String get connecting => zh ? '连接中' : 'Connecting';
  String get disconnected => zh ? '未连接' : 'Not connected';

  // ── 顶栏 ──────────────────────────────────────────
  String get turnOn => zh ? '开灯' : 'Turn on';
  String get turnOff => zh ? '关灯' : 'Turn off';
  String get settings => zh ? '设置' : 'Settings';
  String get devices => zh ? '蓝牙设备' : 'Bluetooth devices';

  // ── 模式 ──────────────────────────────────────────
  String get modeOff => zh ? '关灯' : 'Off';
  String get modeWhite => zh ? '白光' : 'White';
  String get modeDrl => zh ? '日行灯' : 'DRL';
  String get modeAmbient => zh ? '氛围灯' : 'Ambient';
  String get modeFlash => zh ? '爆闪' : 'Strobe';
  String get modeUnknown => zh ? '未知' : 'Unknown';

  String get hintWhite =>
      zh ? '射灯白光常亮，亮度可调' : 'Spotlights on white, brightness adjustable';
  String get hintDrl => zh ? '只亮日行灯，白天示宽用' : 'Daytime running lights only';
  String get hintAmbient =>
      zh ? '只亮灯外圈那圈黄光' : 'Only the amber ring around each lamp';
  String get hintFlash =>
      zh ? '白光三连闪，四组一起闪' : 'White triple flash — all four groups together';

  // ── 三个功能（每组灯的三路）────────────────────────
  String get fnSpot => zh ? '射灯白光' : 'Spotlight';
  String get fnDrl => zh ? '日行灯' : 'DRL';
  String get fnAmbient => zh ? '氛围灯' : 'Ambient';

  // ── 灯组 ──────────────────────────────────────────
  String get groupBumper => zh ? '前包围' : 'Bumper';
  String get groupPillarLow => zh ? '立柱下' : 'Pillar Low';
  String get groupPillarHigh => zh ? '立柱上' : 'Pillar High';
  String get groupRoof => zh ? '车顶' : 'Roof';

  String get subBumper => zh ? '保险杠两侧' : 'Bumper sides';
  String get subPillarLow => zh ? 'A 柱下' : 'Lower A-pillar';
  String get subPillarHigh => zh ? 'A 柱上' : 'Upper A-pillar';
  String get subRoof => zh ? '行李架' : 'Roof rack';

  // ── 主页 ──────────────────────────────────────────
  String groupCount(int on, int total) =>
      zh ? '$on/$total 组' : '$on/$total groups';
  String get brightness => zh ? '亮度' : 'Brightness';
  String get brightnessLocked =>
      zh ? '该模式亮度固定' : 'Fixed brightness in this mode';
  String get channelDetail => zh ? '分路控制' : 'Channels';

  // ── 分路控制页 ────────────────────────────────────
  String get channelHint => zh
      ? '12 路直接开关，想点亮哪一路就点哪一路，不受当前模式限制。\n切换模式会按该模式重新设置这 12 路。'
      : 'Direct control over all 12 channels — switch on any of them, regardless of the current mode. Changing mode resets all 12.';
  String channelNo(int ch) => zh ? '通道 CH$ch' : 'Channel CH$ch';
  String get litNow => zh ? '亮着' : 'On';
  String get customized => zh ? '已自定义' : 'Custom';
  String customizedHint(String mode) => zh
      ? '这 12 路已经手动改过，和「$mode」的默认不一样了。点一下下面的模式按钮就能恢复。'
      : 'These 12 channels were changed by hand and no longer match "$mode". Tap a mode button below to reset.';

  // ── 固件版本不匹配 ────────────────────────────────
  String get fwMismatch => zh ? '固件版本不匹配' : 'Firmware version mismatch';
  String fwMismatchDetail(int device, int need) => zh
      ? '控制器上是 v$device 的固件，这个 App 需要 v$need。\n'
          '界面显示的状态不可信，请把 smart_spotlight_ble.ino 重新烧一遍。'
      : 'The controller runs firmware v$device but this app needs v$need.\n'
          'The status shown here is unreliable — reflash smart_spotlight_ble.ino.';

  // ── 车图 ──────────────────────────────────────────
  String get noCarImage => zh ? '还没有车辆图片' : 'No vehicle image yet';
  String get noCarImageHint => zh
      ? '把越野车图片放到\nassets/images/car.png\n然后重新运行'
      : 'Put the vehicle photo at\nassets/images/car.png\nthen run again';

  // ── 设备选择 ──────────────────────────────────────
  String get pickDevice => zh ? '选择射灯控制器' : 'Select controller';
  String get rescan => zh ? '重新搜索' : 'Rescan';
  String get scanningShort => zh ? '正在搜索…' : 'Scanning…';
  String get noDeviceFound =>
      zh ? '没找到设备，确认控制器已上电' : 'No devices found — check the controller is powered';
  String get unknownDevice => zh ? '未知设备' : 'Unknown device';
  String get spotlightBadge => zh ? '射灯' : 'Light';

  // ── 设置页 ────────────────────────────────────────
  String get language => zh ? '语言' : 'Language';
  String get langChinese => '中文';
  String get langEnglish => 'English';
  String get deviceSection => zh ? '设备' : 'Device';
  String get aboutSection => zh ? '关于' : 'About';
  String get disconnect => zh ? '断开连接' : 'Disconnect';
  String get notConnectedYet => zh ? '尚未连接设备' : 'No device connected';
  String get version => zh ? '版本' : 'Version';
  String get appDesc => zh ? '越野射灯蓝牙控制器' : 'Off-road light BLE controller';

  // ── 蓝牙提示 ──────────────────────────────────────
  String get bleScanning => zh ? '正在搜索射灯…' : 'Searching for the controller…';
  String get bleNoneFound => zh
      ? '没有找到设备，请确认射灯控制器已上电'
      : 'No devices found — make sure the controller is powered on';
  String bleFoundN(int n) =>
      zh ? '找到 $n 个设备，点击选择' : 'Found $n device(s) — tap to select';
  String bleConnectingTo(String name) =>
      zh ? '正在连接 $name…' : 'Connecting to $name…';
  String get bleConnected => zh ? '已连接' : 'Connected';
  String get bleTimeout => zh ? '连接超时，请重试' : 'Connection timed out — please retry';
  String bleConnectFailed(Object e) =>
      zh ? '连接失败: $e' : 'Connection failed: $e';
  String get bleLost => zh ? '射灯已断开' : 'Controller disconnected';
  String bleRetryIn(int sec) =>
      zh ? '$sec 秒后尝试重连…' : 'Reconnecting in ${sec}s…';
  String bleRetryFailed(Object e) => zh ? '重连失败: $e' : 'Reconnect failed: $e';
  String get bleAutoConnecting =>
      zh ? '正在自动连接上次的射灯…' : 'Reconnecting to the last controller…';
  String get bleNoWritable => zh ? '未找到可写特征，断开' : 'No writable characteristic — disconnecting';
  String bleFallbackWrite(Object uuid) => zh
      ? '未找到标准写特征，改用 $uuid'
      : 'Standard write characteristic missing — using $uuid';
  String get bleNoNotify => zh
      ? '未找到状态上报特征，车上改了状态手机不会自动刷新'
      : 'No status characteristic — changes made on the vehicle will not show here';
  String bleNotifyFailed(Object e) =>
      zh ? '订阅状态上报失败: $e' : 'Failed to subscribe to status: $e';
  String bleSendFailed(Object e) => zh ? '发送失败: $e' : 'Send failed: $e';
  String get bleMtuSkipped =>
      zh ? 'MTU 协商跳过，用默认 23' : 'MTU negotiation skipped — using default 23';
  String bleScanError(Object e) => zh ? '扫描出错: $e' : 'Scan error: $e';
  String bleScanFailed(Object e) => zh ? '扫描失败: $e' : 'Scan failed: $e';
  String get bleUnsupported => zh ? '这台手机不支持蓝牙' : 'This phone does not support Bluetooth';
  String get blePermissionNeeded => zh
      ? '需要蓝牙和位置权限才能搜索射灯（请在系统设置里开启）'
      : 'Bluetooth and location permissions are required to scan (enable them in Settings)';
  String get bleUnauthorized => zh
      ? '蓝牙权限被拒绝，请到系统设置里允许本 App 使用蓝牙'
      : 'Bluetooth permission denied — allow it for this app in Settings';
  String bleAdapterOff(String state) => zh
      ? '蓝牙$state，请打开蓝牙后重试'
      : 'Bluetooth is $state — turn it on and retry';
  String get bleNotFoundNearby =>
      zh ? '附近没有识别到射灯，请手动选择' : 'No controller detected nearby — pick one manually';

  // 蓝牙适配器状态
  String adapterOn() => zh ? '已开启' : 'on';
  String adapterOff() => zh ? '已关闭' : 'off';
  String adapterTurningOn() => zh ? '正在开启' : 'turning on';
  String adapterTurningOff() => zh ? '正在关闭' : 'turning off';
  String adapterUnauthorized() => zh ? '未授权' : 'unauthorized';
  String adapterUnavailable() => zh ? '不支持' : 'unavailable';
  String adapterUnknown() => zh ? '未知' : 'unknown';
}
