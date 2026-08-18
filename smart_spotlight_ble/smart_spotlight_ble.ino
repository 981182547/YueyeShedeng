/*
 * 智能越野射灯控制器 —— ESP32-C3 / Arduino IDE 版（BLE 手机控制）
 *
 * 这是【新固件】，与旧的 smart_spotlight_c3 并存，互不影响。
 * 相比旧版新增：BLE 手机控制、8 个灯位独立开关、NVS 掉电记忆、状态主动上报。
 *
 * ── 灯位与通道 ─────────────────────────────────────────────
 * 8 个灯位（对应车上的物理位置），每个灯位有黄/白两路，共 16 路，占满一片 PCA9685：
 *
 *   灯位 ID   位置          黄光通道      白光通道
 *   0        前包围左       CH0          CH8
 *   1        前包围右       CH1          CH9
 *   2        立柱下左       CH2          CH10
 *   3        立柱下右       CH3          CH11
 *   4        立柱上左       CH4          CH12
 *   5        立柱上右       CH5          CH13
 *   6        车顶左         CH6          CH14
 *   7        车顶右         CH7          CH15
 *
 * 分组（手机上点一下开关一整组），编号和车图上标的一致：
 *   组 0 →「1」前包围(灯位 0,1)   组 1 →「2」立柱下(2,3)
 *   组 2 →「3」立柱上(4,5)        组 3 →「4」车顶(6,7)
 *
 *   前包围 = 保险杠两侧那对大圆灯
 *   立柱下 = A 柱上【下面】那对圆灯
 *   立柱上 = A 柱上【上面】那对圆灯
 *   车顶   = 行李架上那对横条灯
 *
 * ── 三个互相独立的维度 ────────────────────────────────────
 *   颜色 userColor：白光 / 黄光            —— 灯发什么色
 *   模式 sysMode  ：常亮/日行/自动/爆闪    —— 灯怎么个亮法
 *   灯位 lampMask ：8 位掩码               —— 哪几个灯位参与
 *
 * 三者正交：切模式不会把颜色弄丢，换颜色不打断当前模式，
 * 开关灯位也不影响前两者。日行、爆闪、常亮全都用 userColor 这个色。
 * 唯一例外：自动模式下遇到下雨会临时改成黄光，雨停自动还原。
 *
 * ── 硬件连接 ───────────────────────────────────────────────
 *   IO4  -> PCA9685 SDA        IO5  -> PCA9685 SCL
 *   IO7  -> 雨滴 DO (低=下雨)   IO8  -> 光敏 DO (低=白天, 高=黑夜)
 *   IO2  <- CI1302 TX          IO3  -> CI1302 RX      (语音，可选)
 *
 * ── Arduino IDE 设置 ───────────────────────────────────────
 *   开发板   : ESP32C3 Dev Module
 *   USB CDC On Boot : Enabled
 *   Partition Scheme: 选带 OTA 或 Huge APP 的方案（BLE 协议栈较大，Default 可能装不下）
 *   依赖库   : 全部为 ESP32 Arduino Core 自带，无需额外安装
 */

#include <Wire.h>
#include <math.h>
#include <Preferences.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

/* CCCD(0x2902)描述符：Core 2.x 要自己加，Core 3.x 会随 NOTIFY 属性自动加。
 * 在 3.x 上再手动加一个会变成两个 CCCD —— 手机订阅时写的是这一个、
 * 固件检查的是那一个，于是 notify() 照发，手机一帧都收不到。
 * 「语音改了灯、手机不同步」十有八九就是栽在这里。 */
#if !defined(ESP_ARDUINO_VERSION_MAJOR) || ESP_ARDUINO_VERSION_MAJOR < 3
  #define NEED_MANUAL_CCCD 1
  #include <BLE2902.h>
#else
  #define NEED_MANUAL_CCCD 0
#endif

/* ==========================================================
 * 一、引脚与参数配置
 * ========================================================== */
#define PIN_I2C_SDA      4
#define PIN_I2C_SCL      5
#define PIN_RAIN         7
#define PIN_LIGHT        8
#define PIN_ASR_RX       2      /* ESP32 收 <- CI1302 TX */
#define PIN_ASR_TX       3      /* ESP32 发 -> CI1302 RX */
#define ASR_BAUD         115200

#define PCA9685_ADDR     0x40
#define PCA9685_FREQ_HZ  1000
#define I2C_SPEED_HZ     400000

#define LAMP_COUNT       8       /* 8 个灯位 */
#define CH_YELLOW_BASE   0       /* 黄光: CH0 + lampId */
#define CH_WHITE_BASE    8       /* 白光: CH8 + lampId */

#define TICK_MS          10      /* 主循环周期 */
#define SMOOTH_FACTOR    0.06f   /* 亮度渐变系数，越小越柔和 */
#define DEBOUNCE_TICKS   8       /* 传感器消抖：连续 8 次(80ms) */

#define DUTY_DAY         20      /* 自动模式-白天亮度 */
#define DUTY_NIGHT       100     /* 自动模式-夜间亮度 */
#define DUTY_DRL         10      /* 日行灯亮度 */

#define FW_VERSION       1       /* 固件协议版本，随状态一起上报 */

HardwareSerial ASR(1);           /* 用 UART1，避开 USB CDC 日志 */
Preferences    prefs;            /* NVS：掉电记忆模式和灯位状态 */

/* ==========================================================
 * 二、BLE 协议定义（必须与手机 App 的 protocol.dart 完全一致）
 *
 *   封包格式: [0xA5][OP][LEN_hi][LEN_lo][payload...]
 * ========================================================== */
#define BLE_DEVICE_NAME   "OffRoad-Light"
#define SERVICE_UUID      "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
#define CHAR_RX_UUID      "6e400002-b5a3-f393-e0a9-e50e24dcca9e"  /* App 写入 */
#define CHAR_TX_UUID      "6e400003-b5a3-f393-e0a9-e50e24dcca9e"  /* 设备上报 */

#define PKT_MAGIC        0xA5

/* App -> 设备 */
#define OP_TEXT          0x01    /* ASCII 调试命令 */
#define OP_MODE          0x10    /* [mode]            切换模式 */
#define OP_LAMP_MASK     0x11    /* [mask]            一次设置全部 8 个灯位 */
#define OP_LAMP          0x12    /* [lampId, on]      单个灯位开关 */
#define OP_GROUP         0x13    /* [groupId, on]     整组开关（两个灯位） */
#define OP_BRIGHT        0x14    /* [duty 0~100]      手动亮度 */
#define OP_QUERY         0x15    /* []                请求上报当前状态 */
#define OP_COLOR         0x16    /* [color]           0=白光 1=黄光 */

/* 设备 -> App（Notify） */
/* [mode, mask, bright, activeColor, night, rain, ver, userColor] */
#define OP_STATUS        0x20

/* ── 颜色和模式是两个【互相独立】的维度 ──────────────────
 *
 *   颜色(userColor)：白光 / 黄光 —— 灯发什么色
 *   模式(sysMode)  ：常亮 / 日行 / 自动 / 爆闪 —— 灯怎么个亮法
 *   灯位(lampMask) ：哪几个灯位参与
 *
 * 三者正交：切模式不会把颜色弄丢，换颜色也不会打断当前模式。
 * 之前把白光/黄光和日行/自动/爆闪塞进同一个枚举，结果是
 * 「选了黄光再点日行」颜色就没了，爆闪也只能沿用上一个模式的颜色。
 */

/* 模式编号 */
enum SysMode {
  MODE_OFF    = 0,   /* 关灯 */
  MODE_STEADY = 1,   /* 常亮：按 manualDuty 常亮 */
  MODE_DRL    = 2,   /* 日行：低亮度常亮 */
  MODE_AUTO   = 3,   /* 自动：光敏定亮度，下雨临时切黄光 */
  MODE_FLASH  = 4,   /* 爆闪：按节奏表闪 */
  MODE_MAX
};

enum LightColor { COLOR_WHITE = 0, COLOR_YELLOW = 1 };

/* ==========================================================
 * 三、PCA9685 驱动（裸寄存器，无需第三方库）
 * ========================================================== */
#define PCA_MODE1        0x00
#define PCA_MODE2        0x01
#define PCA_LED0_ON_L    0x06
#define PCA_PRESCALE     0xFE

#define MODE1_RESTART    0x80
#define MODE1_AI         0x20
#define MODE1_SLEEP      0x10
#define MODE1_ALLCALL    0x01

static void pcaWrite(uint8_t reg, uint8_t val) {
  Wire.beginTransmission(PCA9685_ADDR);
  Wire.write(reg);
  Wire.write(val);
  Wire.endTransmission();
}

static void pcaWriteLed(uint8_t ch, uint16_t on, uint16_t off) {
  Wire.beginTransmission(PCA9685_ADDR);
  Wire.write(PCA_LED0_ON_L + 4 * ch);
  Wire.write(on & 0xFF);
  Wire.write(on >> 8);
  Wire.write(off & 0xFF);
  Wire.write(off >> 8);
  Wire.endTransmission();
}

static void pca9685Init(uint32_t freqHz) {
  Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL, I2C_SPEED_HZ);

  pcaWrite(PCA_MODE1, MODE1_SLEEP);              /* 睡眠态才能改 PRESCALE */

  uint8_t prescale = (uint8_t)(roundf(25000000.0f / (4096.0f * freqHz)) - 1);
  if (prescale < 3) prescale = 3;
  pcaWrite(PCA_PRESCALE, prescale);

  pcaWrite(PCA_MODE1, MODE1_AI | MODE1_ALLCALL);
  delay(5);
  pcaWrite(PCA_MODE1, MODE1_RESTART | MODE1_AI | MODE1_ALLCALL);
  pcaWrite(PCA_MODE2, 0x04);                     /* OUTDRV = 推挽 */

  for (int i = 0; i < 16; i++) pcaWriteLed(i, 0, 0x1000);   /* 全灭 */

  Serial.printf("[init] PCA9685 就绪: %luHz prescale=%u\n",
                (unsigned long)freqHz, prescale);
}

/* 设置单个通道占空比 0~100%。
 * on 相位按通道号错开，16 路同时点亮时电源尖峰会小很多。 */
static void pcaSetChannel(uint8_t ch, int duty) {
  if (duty < 0)   duty = 0;
  if (duty > 100) duty = 100;
  if (duty == 0) {
    pcaWriteLed(ch, 0, 0x1000);                  /* full OFF */
  } else if (duty == 100) {
    pcaWriteLed(ch, 0x1000, 0);                  /* full ON  */
  } else {
    uint16_t on  = (uint16_t)(ch * 256) & 0x0FFF;
    uint16_t len = (uint16_t)(duty * 4096 / 100);
    uint16_t off = (on + len) & 0x0FFF;
    pcaWriteLed(ch, on, off);
  }
}

/* 只在数值变化时才刷 I2C，避免每个 tick 都写满 16 路把总线占死 */
static int lastDuty[16] = {
  -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1
};

static void pcaSetChannelCached(uint8_t ch, int duty) {
  if (duty != lastDuty[ch]) {
    pcaSetChannel(ch, duty);
    lastDuty[ch] = duty;
  }
}

/* ==========================================================
 * 四、运行状态
 * ========================================================== */
/* 爆闪节奏表：{持续ms, 亮度%}（三连闪 + 间隔）
 * 想改快慢/闪几下，只动这张表就行 */
struct FlashStep { uint16_t ms; uint8_t duty; };
static const FlashStep flashPattern[] = {
  {  50, 100 },
  {  50,   0 },
  {  50, 100 },
  {  50,   0 },
  {  50, 100 },
  { 300,   0 },
};
#define FLASH_STEPS (sizeof(flashPattern) / sizeof(flashPattern[0]))

static SysMode    sysMode    = MODE_STEADY;    /* 开机模式（会被 NVS 覆盖） */
static uint8_t    lampMask   = 0xFF;           /* 8 个灯位的开关位图，默认全开 */
static uint8_t    manualDuty = 100;            /* 常亮模式下的亮度 */

/* 用户选的颜色：一直保持，切模式不会动它，存 NVS */
static LightColor userColor = COLOR_WHITE;
/* 这一刻真正输出的颜色：正常等于 userColor，
   只有自动模式遇到下雨才临时改成黄光（穿透雨雾），雨停自动还原 */
static LightColor activeColor = COLOR_WHITE;

static float curYellow = 0.0f, curWhite = 0.0f; /* 渐变中的实际亮度 */

/* 传感器状态：开机默认 天亮(0) / 没雨(1) */
static int lightStable = 0, lightCnt = 0;
static int rainStable  = 1, rainCnt  = 0;
static int lastRain    = 1;

static uint32_t flashIdx = 0, flashMs = 0, logMs = 0;
static const char *reason = "Boot";

/* 状态有变化时置位，下一个 tick 统一上报（避免一次操作发好几包） */
static bool     statusDirty = true;
static uint32_t statusMs    = 0;

/* ==========================================================
 * 五、NVS 掉电记忆
 *
 * 用户设过的模式和灯位开关要记住，下次上电直接恢复成上次的样子。
 * 只在值真的变了的时候写，NVS 有擦写寿命，别每个 tick 都写。
 * ========================================================== */
static void saveSettings() {
  prefs.putUChar("mode", (uint8_t)sysMode);
  prefs.putUChar("mask", lampMask);
  prefs.putUChar("duty", manualDuty);
  prefs.putUChar("color", (uint8_t)userColor);
  Serial.printf("[NVS] 已保存 mode=%u color=%s mask=0x%02X duty=%u\n",
                (unsigned)sysMode,
                userColor == COLOR_WHITE ? "白" : "黄",
                lampMask, manualDuty);
}

static void loadSettings() {
  prefs.begin("spotlight", false);
  /* 出厂默认：白光、常亮、全部灯位打开、100% —— 用户没设置过就是白光 */
  uint8_t m = prefs.getUChar("mode", MODE_STEADY);
  sysMode    = (m < MODE_MAX) ? (SysMode)m : MODE_STEADY;
  lampMask   = prefs.getUChar("mask", 0xFF);
  manualDuty = prefs.getUChar("duty", 100);
  if (manualDuty > 100) manualDuty = 100;
  userColor  = prefs.getUChar("color", COLOR_WHITE) ? COLOR_YELLOW : COLOR_WHITE;
  activeColor = userColor;
  Serial.printf("[NVS] 已恢复 mode=%u color=%s mask=0x%02X duty=%u\n",
                (unsigned)sysMode,
                userColor == COLOR_WHITE ? "白" : "黄",
                lampMask, manualDuty);
}

/* ==========================================================
 * 六、BLE 服务端
 * ========================================================== */
static BLEServer         *bleServer = nullptr;
static BLECharacteristic *txChar    = nullptr;
static bool               bleConnected = false;

/* 累计发出去多少帧状态。串口每秒打印它 ——
 * 排查「语音改了灯、手机没跟着变」时，先看这个数字动没动：
 *   不动  = 固件没发（没连上，或者 txChar 没建起来）
 *   在涨但手机没反应 = 帧发出去了，问题在手机那边没订阅上 */
static uint32_t notifyCount = 0;

/* 把当前状态打包成一帧 0xA5 上报给手机。
 * App 收到就刷新界面 —— 语音、传感器、手机三方谁改了状态，手机上都能立刻看到。 */
static void notifyStatus() {
  if (!bleConnected || txChar == nullptr) return;

  uint8_t pkt[4 + 8];
  pkt[0] = PKT_MAGIC;
  pkt[1] = OP_STATUS;
  pkt[2] = 0;
  pkt[3] = 8;
  pkt[4] = (uint8_t)sysMode;
  pkt[5] = lampMask;
  pkt[6] = manualDuty;
  pkt[7] = (uint8_t)activeColor;      /* 这一刻真实输出的颜色（自动模式遇雨会变） */
  pkt[8] = lightStable ? 1 : 0;       /* 1 = 夜晚 */
  pkt[9] = rainStable ? 0 : 1;        /* 1 = 正在下雨 */
  pkt[10] = FW_VERSION;
  pkt[11] = (uint8_t)userColor;       /* 用户选的颜色，App 的白/黄切换按它显示 */

  txChar->setValue(pkt, sizeof(pkt));
  txChar->notify();
  notifyCount++;
}

/* NVS 延迟写入：变化停下来之后才落盘 */
static bool     savePending = false;
static uint32_t saveTimer   = 0;

/* 标记状态已变化：下个 tick 上报，并排队一次存盘。
 * 传感器引起的变化（自动模式切黄光）只上报不存盘，那不是用户的设置。
 *
 * 存盘不能立刻做：拖亮度滑条会连发几十条指令，条条都写 NVS 是在白白
 * 消耗闪存擦写寿命。这里只排队，等状态稳定 2 秒再真正写一次。 */
static void markDirty(bool persist = true) {
  statusDirty = true;
  if (persist) {
    savePending = true;
    saveTimer   = 0;      /* 每来一次新变化就重新计时 */
  }
}

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *srv) override {
    bleConnected = true;
    Serial.println("[BLE] 手机已连接");
    statusDirty = true;                /* 连上先推一帧当前状态过去 */
  }
  void onDisconnect(BLEServer *srv) override {
    bleConnected = false;
    Serial.println("[BLE] 手机已断开，重新开始广播");
    BLEDevice::startAdvertising();     /* 断开后必须重新广播，否则再也连不上 */
  }
};

/* 解析 App 发来的封包。
 * BLE 一包最多几十字节，我们的指令都很短，不会被分片，直接按帧解析即可。 */
static void handlePacket(uint8_t op, const uint8_t *data, size_t len) {
  switch (op) {
    case OP_MODE: {
      if (len < 1) return;
      uint8_t m = data[0];
      if (m >= MODE_MAX) return;
      if (sysMode != (SysMode)m) {
        sysMode = (SysMode)m;
        if (sysMode == MODE_FLASH) { flashIdx = 0; flashMs = 0; }
        Serial.printf("[BLE] 切换模式: %u\n", (unsigned)m);
        markDirty();
      }
      break;
    }
    case OP_LAMP_MASK: {
      if (len < 1) return;
      if (lampMask != data[0]) {
        lampMask = data[0];
        Serial.printf("[BLE] 灯位掩码: 0x%02X\n", lampMask);
        markDirty();
      }
      break;
    }
    case OP_LAMP: {
      if (len < 2) return;
      uint8_t id = data[0];
      if (id >= LAMP_COUNT) return;
      uint8_t next = data[1] ? (lampMask | (1 << id)) : (lampMask & ~(1 << id));
      if (next != lampMask) {
        lampMask = next;
        Serial.printf("[BLE] 灯位 %u -> %s (掩码 0x%02X)\n",
                      id, data[1] ? "开" : "关", lampMask);
        markDirty();
      }
      break;
    }
    case OP_GROUP: {
      /* 一组 = 相邻两个灯位（左右各一）：组 0 = 灯位 0,1；组 1 = 2,3 … */
      if (len < 2) return;
      uint8_t g = data[0];
      if (g >= LAMP_COUNT / 2) return;
      uint8_t bits = 0x03 << (g * 2);
      uint8_t next = data[1] ? (lampMask | bits) : (lampMask & ~bits);
      if (next != lampMask) {
        lampMask = next;
        Serial.printf("[BLE] 灯组 %u -> %s (掩码 0x%02X)\n",
                      g, data[1] ? "开" : "关", lampMask);
        markDirty();
      }
      break;
    }
    case OP_BRIGHT: {
      if (len < 1) return;
      uint8_t d = data[0] > 100 ? 100 : data[0];
      if (manualDuty != d) {
        manualDuty = d;
        Serial.printf("[BLE] 亮度: %u%%\n", manualDuty);
        markDirty();
      }
      break;
    }
    case OP_COLOR: {
      /* 只改颜色，不碰模式 —— 当前是日行就还是日行，是爆闪就还接着闪 */
      if (len < 1) return;
      LightColor c = data[0] ? COLOR_YELLOW : COLOR_WHITE;
      if (userColor != c) {
        userColor = c;
        Serial.printf("[BLE] 颜色: %s\n", c == COLOR_WHITE ? "白光" : "黄光");
        markDirty();
      }
      break;
    }
    case OP_QUERY:
      statusDirty = true;              /* App 主动要一次当前状态 */
      break;
    case OP_TEXT:
      Serial.printf("[BLE] 调试文本: %.*s\n", (int)len, (const char *)data);
      break;
    default:
      Serial.printf("[BLE] 未知操作码: 0x%02X\n", op);
      break;
  }
}

class RxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *ch) override {
    /* 用 getData()/getLength() 而不是 getValue()：
       getValue() 的返回类型在 ESP32 Core 2.x(std::string) 和 3.x(String) 之间改过，
       而这两个接口在新旧版本上签名一致，换 core 版本不用动代码。 */
    const uint8_t *buf = ch->getData();
    size_t n = ch->getLength();
    if (buf == nullptr || n < 4) return;

    /* 一次写入里可能带多个封包，循环解完 */
    size_t i = 0;
    while (i + 4 <= n) {
      if (buf[i] != PKT_MAGIC) { i++; continue; }   /* 找包头 */
      uint8_t  op  = buf[i + 1];
      uint16_t len = ((uint16_t)buf[i + 2] << 8) | buf[i + 3];
      if (i + 4 + len > n) break;                   /* 收不全，丢弃剩余 */
      handlePacket(op, buf + i + 4, len);
      i += 4 + len;
    }
  }
};

static void bleInit() {
  BLEDevice::init(BLE_DEVICE_NAME);
  bleServer = BLEDevice::createServer();
  bleServer->setCallbacks(new ServerCallbacks());

  BLEService *svc = bleServer->createService(SERVICE_UUID);

  BLECharacteristic *rxChar = svc->createCharacteristic(
      CHAR_RX_UUID,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  rxChar->setCallbacks(new RxCallbacks());

  txChar = svc->createCharacteristic(
      CHAR_TX_UUID,
      BLECharacteristic::PROPERTY_NOTIFY | BLECharacteristic::PROPERTY_READ);
#if NEED_MANUAL_CCCD
  /* Core 2.x：没有 2902 描述符手机就订阅不了通知，必须手动加 */
  txChar->addDescriptor(new BLE2902());
  Serial.println("[BLE] CCCD 手动添加(Core 2.x)");
#else
  /* Core 3.x：NOTIFY 属性会自动带上 CCCD，这里再加就重复了 */
  Serial.println("[BLE] CCCD 由内核自动添加(Core 3.x)");
#endif

  svc->start();

  BLEAdvertising *adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  /* 这两行是 iPhone 连接问题的官方推荐解法，安卓上也没坏处 */
  adv->setMinPreferred(0x06);
  adv->setMinPreferred(0x12);
  BLEDevice::startAdvertising();

  Serial.printf("[BLE] 广播中，设备名: %s\n", BLE_DEVICE_NAME);
}

/* ==========================================================
 * 七、语音指令（沿用旧固件的 CI1302，可选）
 * ========================================================== */
static int debounceRead(int pin, int &stable, int &cnt) {
  int v = digitalRead(pin);
  if (v == stable)                 cnt = 0;
  else if (++cnt >= DEBOUNCE_TICKS) { stable = v; cnt = 0; }
  return stable;
}

static bool asrReadCmd(char *out, size_t size) {
  if (!ASR.available()) return false;
  delay(5);                                      /* 等一帧收完 */
  size_t n = 0;
  while (ASR.available() && n < size - 1) {
    char c = (char)ASR.read();
    if (c >= 'a' && c <= 'z') c -= 32;
    if (c > ' ') out[n++] = c;
  }
  out[n] = '\0';
  return n > 0;
}

/* 语音改的也是同一套状态，所以照样存 NVS + 上报手机 */
static void handleVoice(const char *cmd) {
  /* 白光/黄光只换颜色，不动模式 —— 和 App 上那个白/黄开关是同一个东西 */
  if (strstr(cmd, "WHT")) {
    userColor = COLOR_WHITE;   Serial.println(">> 语音: 白光");
    if (sysMode == MODE_OFF) sysMode = MODE_STEADY;   /* 关着灯说颜色，顺手点亮 */
  } else if (strstr(cmd, "YEL") || strstr(cmd, "RED")) {
    userColor = COLOR_YELLOW;  Serial.println(">> 语音: 黄光");
    if (sysMode == MODE_OFF) sysMode = MODE_STEADY;
  } else if (strstr(cmd, "BLBL") || strstr(cmd, "BL")) {
    if (sysMode != MODE_FLASH) { flashIdx = 0; flashMs = 0; }
    sysMode = MODE_FLASH;  Serial.println(">> 语音: 爆闪");
  } else if (strstr(cmd, "AUTO")) {
    sysMode = MODE_AUTO;   Serial.println(">> 语音: 自动");
  } else if (strstr(cmd, "DRL")) {
    sysMode = MODE_DRL;    Serial.println(">> 语音: 日行灯");
  } else if (strstr(cmd, "OFF")) {
    sysMode = MODE_OFF;    Serial.println(">> 语音: 关灯");
  } else if (strstr(cmd, "ON")) {
    sysMode = MODE_STEADY; Serial.println(">> 语音: 开灯");
  } else {
    Serial.print(">> [语音] 未匹配, HEX:");
    for (size_t i = 0; cmd[i]; i++) Serial.printf(" %02X", (uint8_t)cmd[i]);
    Serial.println();
    return;
  }
  markDirty();
}

/* ==========================================================
 * 八、setup / loop
 * ========================================================== */
void setup() {
  Serial.begin(115200);                          /* USB CDC 日志 */
  ASR.begin(ASR_BAUD, SERIAL_8N1, PIN_ASR_RX, PIN_ASR_TX);

  pinMode(PIN_RAIN,  INPUT_PULLUP);
  pinMode(PIN_LIGHT, INPUT_PULLUP);

  loadSettings();                                /* 先恢复上次的设置 */
  pca9685Init(PCA9685_FREQ_HZ);
  bleInit();

  Serial.println("[init] 系统启动完毕  FW=BLE-v1");
}

void loop() {
  char cmd[128];

  /* ---------- 0. 传感器轮询 ---------- */
  int curLight = debounceRead(PIN_LIGHT, lightStable, lightCnt);  /* 0=白天 1=黑夜 */
  int curRain  = debounceRead(PIN_RAIN,  rainStable,  rainCnt);   /* 0=下雨 1=干燥 */

  /* 雨滴边沿：只有自动模式才让它抢颜色，其它模式一律听用户的 */
  if (curRain != lastRain) {
    if (sysMode == MODE_AUTO) {
      Serial.println(curRain == 0 ? ">> [传感器] 下雨，临时切黄光穿透雨雾"
                                  : ">> [传感器] 雨停，还原成所选颜色");
    }
    lastRain = curRain;
  }

  /* ---------- 1. 语音指令 ---------- */
  if (asrReadCmd(cmd, sizeof(cmd))) {
    Serial.printf("[语音] 收到指令: %s\n", cmd);
    handleVoice(cmd);
  }

  /* ---------- 2. 按模式算出【颜色】和【亮度】 ---------- */
  int  targetDuty  = 0;
  bool hardSwitch  = false;      /* 爆闪要硬切，不能走渐变 */

  /* 颜色一律跟着用户选的走 —— 日行、爆闪、常亮全都用这个色。
     唯一的例外在下面的自动模式里：下雨时临时改黄光。 */
  activeColor = userColor;

  switch (sysMode) {
    case MODE_OFF:
      targetDuty = 0;
      reason = "Off";
      break;

    case MODE_STEADY:
      targetDuty = manualDuty;
      reason = "Steady";
      break;

    case MODE_DRL:
      targetDuty = DUTY_DRL;
      reason = "DRL";
      break;

    case MODE_AUTO:
      /* 光敏定亮度。下雨临时切黄光穿透雨雾，雨停自动还原成用户选的颜色 */
      targetDuty = (curLight == 0) ? DUTY_DAY : DUTY_NIGHT;
      if (curRain == 0) activeColor = COLOR_YELLOW;
      reason = (curLight == 0) ? "Auto/Day" : "Auto/Night";
      break;

    case MODE_FLASH: {
      flashMs += TICK_MS;
      if (flashMs >= flashPattern[flashIdx].ms) {
        flashMs  = 0;
        flashIdx = (flashIdx + 1) % FLASH_STEPS;
      }
      targetDuty = flashPattern[flashIdx].duty;
      hardSwitch = true;
      reason = "Flash";
      break;
    }

    default:
      targetDuty = 0;
      break;
  }

  /* 实际输出的颜色一变就上报，App 那边的显示才跟得上（比如雨天自动转黄） */
  static LightColor lastActive = COLOR_WHITE;
  if (activeColor != lastActive) {
    lastActive  = activeColor;
    statusDirty = true;
  }

  /* ---------- 3. 颜色路由 + 渐变 ---------- */
  float targetYellow = (activeColor == COLOR_YELLOW) ? targetDuty : 0.0f;
  float targetWhite  = (activeColor == COLOR_WHITE)  ? targetDuty : 0.0f;

  if (hardSwitch) {
    curYellow = targetYellow;
    curWhite  = targetWhite;
  } else {
    curYellow += (targetYellow - curYellow) * SMOOTH_FACTOR;
    curWhite  += (targetWhite  - curWhite ) * SMOOTH_FACTOR;
    if (fabsf(targetYellow - curYellow) < 0.5f) curYellow = targetYellow;
    if (fabsf(targetWhite  - curWhite ) < 0.5f) curWhite  = targetWhite;
  }

  /* ---------- 4. 按灯位掩码输出 ---------- */
  int dutyY = (int)(curYellow + 0.5f);
  int dutyW = (int)(curWhite  + 0.5f);
  for (uint8_t i = 0; i < LAMP_COUNT; i++) {
    bool on = lampMask & (1 << i);               /* 这个灯位被用户关掉了就不亮 */
    pcaSetChannelCached(CH_YELLOW_BASE + i, on ? dutyY : 0);
    pcaSetChannelCached(CH_WHITE_BASE  + i, on ? dutyW : 0);
  }

  /* ---------- 5. NVS 延迟落盘 ---------- */
  if (savePending) {
    saveTimer += TICK_MS;
    if (saveTimer >= 2000) {          /* 2 秒内没有新变化才写 */
      saveSettings();
      savePending = false;
      saveTimer   = 0;
    }
  }

  /* ---------- 6. 状态上报 ---------- */
  /* 有变化就报。爆闪时状态每 50ms 就变一次，不能跟着报，
     所以只报"设置"层面的变化，不报闪烁的瞬时亮度。 */
  if (statusDirty) {
    notifyStatus();
    statusDirty = false;
  }
  /* 另外每 2 秒兜底报一次，防止某一帧 notify 丢包导致手机显示卡在旧状态 */
  statusMs += TICK_MS;
  if (statusMs >= 2000) {
    statusMs = 0;
    notifyStatus();
  }

  /* ---------- 7. 串口状态打印（每 1s） ---------- */
  logMs += TICK_MS;
  if (logMs >= 1000) {
    logMs = 0;
    Serial.printf("Mode:%s Color:%s(选%s) Mask:0x%02X Light:%s Rain:%s BLE:%s Notify:%lu | Y:%d%% W:%d%%\n",
                  reason,
                  (activeColor == COLOR_WHITE) ? "White" : "Yellow",
                  (userColor == COLOR_WHITE) ? "W" : "Y",
                  lampMask,
                  curLight ? "Night" : "Day",
                  curRain  ? "Dry"   : "Rain",
                  bleConnected ? "ON" : "--",
                  (unsigned long)notifyCount,
                  dutyY, dutyW);
  }

  delay(TICK_MS);
}
