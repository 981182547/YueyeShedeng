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
  String get partial => zh ? '半开' : 'Partial';
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
  String get modeSteady => zh ? '常亮' : 'Steady';
  String get modeDrl => zh ? '日行' : 'DRL';
  String get modeAuto => zh ? '自动' : 'Auto';
  String get modeFlash => zh ? '爆闪' : 'Strobe';
  String get modeUnknown => zh ? '未知' : 'Unknown';

  String get hintSteady => zh ? '按设定亮度一直亮着' : 'Stays on at the set brightness';
  String get hintDrl => zh ? '低亮度长亮，白天示宽用' : 'Dim and constant, for daytime running';
  String get hintAuto =>
      zh ? '光敏定亮度，下雨临时转黄光' : 'Light sensor sets brightness; rain switches to yellow';
  String get hintFlash => zh ? '三连闪 + 间隔，警示用' : 'Triple flash + pause, for warning';

  // ── 颜色 ──────────────────────────────────────────
  String get white => zh ? '白光' : 'White';
  String get yellow => zh ? '黄光' : 'Yellow';
  String get rainOverride =>
      zh ? '检测到下雨，已临时转黄光' : 'Rain detected — temporarily on yellow';

  // ── 灯组 ──────────────────────────────────────────
  String get groupBumper => zh ? '前包围' : 'Bumper';
  String get groupPillarLow => zh ? '立柱下' : 'Pillar Low';
  String get groupPillarHigh => zh ? '立柱上' : 'Pillar High';
  String get groupRoof => zh ? '车顶' : 'Roof';

  String get subBumper => zh ? '保险杠两侧 · 2 只' : 'Bumper sides · 2 lamps';
  String get subPillarLow => zh ? 'A 柱下 · 2 只' : 'Lower A-pillar · 2 lamps';
  String get subPillarHigh => zh ? 'A 柱上 · 2 只' : 'Upper A-pillar · 2 lamps';
  String get subRoof => zh ? '行李架 · 2 只' : 'Roof rack · 2 lamps';

  // ── 灯位 ──────────────────────────────────────────
  String get lampBumperL => zh ? '前包围左' : 'Bumper L';
  String get lampBumperR => zh ? '前包围右' : 'Bumper R';
  String get lampPillarLowL => zh ? '立柱下左' : 'Pillar Low L';
  String get lampPillarLowR => zh ? '立柱下右' : 'Pillar Low R';
  String get lampPillarHighL => zh ? '立柱上左' : 'Pillar High L';
  String get lampPillarHighR => zh ? '立柱上右' : 'Pillar High R';
  String get lampRoofL => zh ? '车顶左' : 'Roof L';
  String get lampRoofR => zh ? '车顶右' : 'Roof R';

  // ── 主页 ──────────────────────────────────────────
  String lampCount(int on, int total) =>
      zh ? '$on/$total 灯位' : '$on/$total lamps';
  String get brightness => zh ? '亮度' : 'Brightness';
  String get singleLamp => zh ? '单灯控制' : 'Single Lamp';

  // ── 单灯页 ────────────────────────────────────────
  String get singleLampHint => zh
      ? '点车图上的光点，或用下面的开关，单独控制每一只灯'
      : 'Tap a light on the photo, or use the switches below, to control each lamp';
  String channels(int yellow, int white) =>
      zh ? '黄光 CH$yellow  ·  白光 CH$white' : 'Yellow CH$yellow  ·  White CH$white';

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
