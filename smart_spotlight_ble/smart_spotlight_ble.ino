/*
 * 智能越野射灯控制器 —— ESP32-C3 / Arduino IDE 版（BLE 手机控制）
 *
 * 这是【新固件】，与旧的 smart_spotlight_c3 并存，互不影响。
 *
 * ── 灯组与通道 ─────────────────────────────────────────────
 * 车上 4 组灯，左右两只并联受同一路控制（点左边点右边都是一起亮）。
 * 每组灯有 3 个功能：射灯白光 / 日行灯 / 氛围灯（外圈那圈黄光）。
 * 4 组 × 3 功能 = 12 路 PWM。PCA9685 有 16 路，按【每组占 4 路、用前 3 路】
 * 排布，每组最后一路空着不接 —— 这样通道号和接线板的分组一一对应。
 *
 *   组  位置      射灯白   日行灯   氛围灯   空
 *   0   前包围     CH0     CH1     CH2     CH3
 *   1   立柱下     CH4     CH5     CH6     CH7
 *   2   立柱上     CH8     CH9     CH10    CH11
 *   3   车顶       CH12    CH13    CH14    CH15
 *
 *   通道号 = 组号 * 4 + 功能号   （功能号 0=射灯白 1=日行灯 2=氛围灯）
 *
 *   前包围 = 保险杠两侧那对大圆灯    立柱下 = A 柱上【下面】那对圆灯
 *   立柱上 = A 柱上【上面】那对圆灯  车顶   = 行李架上那对横条灯
 *
 * ── 模式决定发什么光 ──────────────────────────────────────
 * 没有独立的"颜色"设置了 —— 选了哪个模式就亮哪一路灯，互斥：
 *
 *   模式        射灯白      日行灯    氛围灯    亮度来源
 *   关闭(0)      -          -        -        全灭
 *   白光(1)      ✓          -        -        manualDuty（手机滑条）
 *   日行灯(2)    -          ✓        -        DUTY_DRL
 *   氛围灯(3)    -          -        ✓        DUTY_AMBIENT
 *   爆闪(4)      ✓按节奏     -        -        节奏表
 *
 * 【黄光不爆闪】是结构上保证的：爆闪只驱动射灯白光那一路，
 * 氛围灯通道在爆闪模式下恒为 0，想闪也闪不了。
 *
 * ── 通道掩码 chMask ───────────────────────────────────────
 * 16 位，第 N 位就是 CH N 的总开关（每组第 4 位恒 0，那一路没接线）。
 * 掩码和模式正交：模式决定"亮哪一路功能"，掩码决定"哪几路允许亮"。
 * 手机上：主页 4 个组开关 = 一次切该组的 3 个位；
 *         详情页 12 个开关 = 逐个切。
 * 唯一例外：爆闪无视掩码，4 组一起闪（警示灯要的就是全车都看得见）。
 *
 * ── 上电默认 ──────────────────────────────────────────────
 * 车子点火后【默认关闭】，模式不做掉电记忆。
 * 亮度和通道掩码照旧存 NVS —— 一开灯就是上次的亮度、上次选的那几组。
 *
 * ── 硬件连接 ───────────────────────────────────────────────
 *   IO4  -> PCA9685 SDA        IO5  -> PCA9685 SCL
 *   IO2  <- CI1302 TX          IO3  -> CI1302 RX      (语音，可选)
 *   IO7 / IO8 原来接雨滴和光敏，现在不用了，空着即可
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
#define PIN_ASR_RX       2      /* ESP32 收 <- CI1302 TX */
#define PIN_ASR_TX       3      /* ESP32 发 -> CI1302 RX */
#define ASR_BAUD         115200

#define PCA9685_ADDR     0x40
#define PCA9685_FREQ_HZ  1000
#define I2C_SPEED_HZ     400000

/* ── 灯组与通道映射 ──────────────────────────────────────
 * 改接线只要改这几个常量，输出级不用动。 */
#define GROUP_COUNT      4       /* 4 组灯 */
#define CH_PER_GROUP     4       /* 接线板 4 路一组，用前 3 路 */
#define FN_COUNT         3       /* 每组 3 个功能 */
#define FN_SPOT          0       /* 射灯白光 */
#define FN_DRL           1       /* 日行灯 */
#define FN_AMB           2       /* 氛围灯（外圈黄光） */
#define CH_TOTAL         (GROUP_COUNT * CH_PER_GROUP)   /* 16 */

/* 组号 + 功能号 -> PCA9685 通道号 */
#define CH_OF(g, fn)     ((uint8_t)((g) * CH_PER_GROUP + (fn)))

/* 掩码默认值：每组低 3 位置 1、第 4 位(空通道)置 0
 * 0b0111 0111 0111 0111 = 0x7777 */
#define CH_MASK_ALL      0x7777

#define TICK_MS          10      /* 主循环周期 */
#define SMOOTH_FACTOR    0.06f   /* 亮度渐变系数，越小越柔和 */

/* 日行灯和氛围灯不调亮度，直接给满 ——
 * 那些灯珠本身就比射灯暗得多，再降就基本看不见了。 */
#define DUTY_DRL         100     /* 日行灯亮度 */
#define DUTY_AMBIENT     100     /* 氛围灯亮度 */

#define FW_VERSION       2       /* 固件协议版本，随状态一起上报 */

HardwareSerial ASR(1);           /* 用 UART1，避开 USB CDC 日志 */
Preferences    prefs;            /* NVS：掉电记忆亮度和通道掩码 */

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
#define OP_CH_MASK       0x11    /* [hi, lo]          一次设置 16 位通道掩码 */
#define OP_CH            0x12    /* [ch, on]          单个通道开关 */
#define OP_GROUP         0x13    /* [groupId, on]     整组开关（该组 3 个功能一起） */
#define OP_BRIGHT        0x14    /* [duty 0~100]      白光模式的亮度 */
#define OP_QUERY         0x15    /* []                请求上报当前状态 */

/* 设备 -> App（Notify） */
/* [mode, maskHi, maskLo, bright, ver] */
#define OP_STATUS        0x20
#define STATUS_LEN       5

/* 模式编号。必须和 App 的 LightMode 一致。 */
enum SysMode {
  MODE_OFF     = 0,   /* 关灯：全灭，上电默认 */
  MODE_WHITE   = 1,   /* 白光：射灯白，按 manualDuty 常亮 */
  MODE_DRL     = 2,   /* 日行灯：只亮日行灯那一路 */
  MODE_AMBIENT = 3,   /* 氛围灯：只亮外圈黄光那一路 */
  MODE_FLASH   = 4,   /* 爆闪：射灯白按节奏表闪，无视掩码 */
  MODE_MAX
};

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
  Wire.write(on  & 0xFF);
  Wire.write(on  >> 8);
  Wire.write(off & 0xFF);
  Wire.write(off >> 8);
  Wire.endTransmission();
}

static void pca9685Init(uint32_t freqHz) {
  Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL, I2C_SPEED_HZ);

  pcaWrite(PCA_MODE1, MODE1_SLEEP);              /* 睡眠态才能改 PRESCALE */
  delay(1);

  uint8_t prescale = (uint8_t)(roundf(25000000.0f / (4096.0f * freqHz)) - 1);
  pcaWrite(PCA_PRESCALE, prescale);
  delay(1);

  pcaWrite(PCA_MODE1, MODE1_AI | MODE1_ALLCALL);
  delay(1);
  pcaWrite(PCA_MODE1, MODE1_RESTART | MODE1_AI | MODE1_ALLCALL);
  pcaWrite(PCA_MODE2, 0x04);                     /* OUTDRV = 推挽 */
  delay(1);

  for (uint8_t ch = 0; ch < CH_TOTAL; ch++) pcaWriteLed(ch, 0, 0x1000);

  Serial.printf("[init] PCA9685 就绪: %luHz prescale=%u\n",
                (unsigned long)freqHz, prescale);
}

/* 设置单个通道占空比 0~100%。
 * on 相位按通道号错开，多路同时点亮时电源尖峰会小很多。 */
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
static int lastDuty[CH_TOTAL] = {
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

/* 上电默认关灯 —— 车子点火不能自己亮起来。模式不做掉电记忆。 */
static SysMode  sysMode    = MODE_OFF;
static uint16_t chMask     = CH_MASK_ALL;      /* 通道掩码，bit N = CH N */
static uint8_t  manualDuty = 100;              /* 白光模式的亮度 */

/* 三个功能各自渐变中的实际亮度 */
static float curFn[FN_COUNT] = { 0.0f, 0.0f, 0.0f };

static uint32_t flashIdx = 0, flashMs = 0, logMs = 0;
static const char *reason = "Boot";

/* 状态有变化时置位，下一个 tick 统一上报（避免一次操作发好几包） */
static bool     statusDirty = true;
static uint32_t statusMs    = 0;

/* 一组灯在掩码里占的 3 个位（第 4 位是空通道，不置位） */
static inline uint16_t groupBits(uint8_t g) {
  return (uint16_t)0x0007 << (g * CH_PER_GROUP);
}

/* ==========================================================
 * 五、NVS 掉电记忆
 *
 * 只记亮度和通道掩码 —— 模式故意不记，点火后一律是关着的。
 * 只在值真的变了的时候写，NVS 有擦写寿命，别每个 tick 都写。
 * ========================================================== */
static void saveSettings() {
  prefs.putUShort("chmask", chMask);
  prefs.putUChar("duty", manualDuty);
  Serial.printf("[NVS] 已保存 mask=0x%04X duty=%u\n", chMask, manualDuty);
}

static void loadSettings() {
  prefs.begin("spotlight", false);
  /* 出厂默认：12 路全开、100% */
  chMask     = prefs.getUShort("chmask", CH_MASK_ALL);
  chMask    &= CH_MASK_ALL;                 /* 空通道那几位强制清掉 */
  manualDuty = prefs.getUChar("duty", 100);
  if (manualDuty > 100) manualDuty = 100;
  Serial.printf("[NVS] 已恢复 mask=0x%04X duty=%u（模式不记忆，开机为关灯）\n",
                chMask, manualDuty);
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
 * App 收到就刷新界面 —— 语音、手机两边谁改了状态，手机上都能立刻看到。 */
static void notifyStatus() {
  if (!bleConnected || txChar == nullptr) return;

  uint8_t pkt[4 + STATUS_LEN];
  pkt[0] = PKT_MAGIC;
  pkt[1] = OP_STATUS;
  pkt[2] = 0;
  pkt[3] = STATUS_LEN;
  pkt[4] = (uint8_t)sysMode;
  pkt[5] = (uint8_t)(chMask >> 8);
  pkt[6] = (uint8_t)(chMask & 0xFF);
  pkt[7] = manualDuty;
  pkt[8] = FW_VERSION;

  txChar->setValue(pkt, sizeof(pkt));
  txChar->notify();
  notifyCount++;
}

/* NVS 延迟写入：变化停下来之后才落盘 */
static bool     savePending = false;
static uint32_t saveTimer   = 0;

/* 标记状态已变化：下个 tick 上报，并排队一次存盘。
 *
 * 存盘不能立刻做：拖亮度滑条会连发几十条指令，条条都写 NVS 是在白白
 * 消耗闪存擦写寿命。这里只排队，等状态稳定 2 秒再真正写一次。
 * 模式变化只上报不存盘 —— 模式本来就不记忆。 */
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

/* 换掩码的统一入口：空通道那几位永远清掉，省得界面发错了把没接线的通道点亮 */
static void applyMask(uint16_t next, const char *who) {
  next &= CH_MASK_ALL;
  if (next == chMask) return;
  chMask = next;
  Serial.printf("[BLE] %s -> 掩码 0x%04X\n", who, chMask);
  markDirty();
}

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
        markDirty(false);              /* 模式不存盘 */
      }
      break;
    }
    case OP_CH_MASK: {
      if (len < 2) return;
      applyMask(((uint16_t)data[0] << 8) | data[1], "通道掩码");
      break;
    }
    case OP_CH: {
      if (len < 2) return;
      uint8_t ch = data[0];
      if (ch >= CH_TOTAL) return;
      uint16_t bit = (uint16_t)1 << ch;
      applyMask(data[1] ? (chMask | bit) : (chMask & ~bit), "单通道");
      break;
    }
    case OP_GROUP: {
      /* 整组开关 = 这组的 3 个功能一起切 */
      if (len < 2) return;
      uint8_t g = data[0];
      if (g >= GROUP_COUNT) return;
      uint16_t bits = groupBits(g);
      applyMask(data[1] ? (chMask | bits) : (chMask & ~bits), "灯组");
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

/* 语音改的也是同一套状态，所以照样上报手机。
 *
 * CI1302 的词条是烧在模块里的，改不了，所以按现有词条重新映射到新模式：
 *   WHT / ON  -> 白光      YEL / RED -> 氛围灯（原来的"黄光"）
 *   DRL       -> 日行灯    BL / BLBL -> 爆闪
 *   OFF       -> 关灯
 *   AUTO      -> 不响应。自动模式整个取消了，宁可不动也别乱切一个模式出来，
 *                否则用户说了句"自动"灯却变成白光，比没反应更让人摸不着头脑。
 */
static void handleVoice(const char *cmd) {
  if (strstr(cmd, "WHT")) {
    sysMode = MODE_WHITE;    Serial.println(">> 语音: 白光");
  } else if (strstr(cmd, "YEL") || strstr(cmd, "RED")) {
    sysMode = MODE_AMBIENT;  Serial.println(">> 语音: 氛围灯");
  } else if (strstr(cmd, "BLBL") || strstr(cmd, "BL")) {
    if (sysMode != MODE_FLASH) { flashIdx = 0; flashMs = 0; }
    sysMode = MODE_FLASH;    Serial.println(">> 语音: 爆闪");
  } else if (strstr(cmd, "AUTO")) {
    Serial.println(">> 语音: 自动 —— 该模式已取消，忽略");
    return;                                      /* 不动模式，也不上报 */
  } else if (strstr(cmd, "DRL")) {
    sysMode = MODE_DRL;      Serial.println(">> 语音: 日行灯");
  } else if (strstr(cmd, "OFF")) {
    sysMode = MODE_OFF;      Serial.println(">> 语音: 关灯");
  } else if (strstr(cmd, "ON")) {
    sysMode = MODE_WHITE;    Serial.println(">> 语音: 开灯");
  } else {
    Serial.print(">> [语音] 未匹配, HEX:");
    for (size_t i = 0; cmd[i]; i++) Serial.printf(" %02X", (uint8_t)cmd[i]);
    Serial.println();
    return;
  }
  markDirty(false);                              /* 模式不存盘 */
}

/* ==========================================================
 * 八、setup / loop
 * ========================================================== */
void setup() {
  Serial.begin(115200);                          /* USB CDC 日志 */
  ASR.begin(ASR_BAUD, SERIAL_8N1, PIN_ASR_RX, PIN_ASR_TX);

  loadSettings();                                /* 恢复亮度和掩码（模式不恢复） */
  pca9685Init(PCA9685_FREQ_HZ);
  bleInit();

  Serial.println("[init] 系统启动完毕  FW=BLE-v2  上电默认关灯");
}

void loop() {
  char cmd[128];

  /* ---------- 1. 语音指令 ---------- */
  if (asrReadCmd(cmd, sizeof(cmd))) {
    Serial.printf("[语音] 收到指令: %s\n", cmd);
    handleVoice(cmd);
  }

  /* ---------- 2. 按模式算出三个功能各自的目标亮度 ----------
     模式是互斥的：同一时刻只有一个功能出光，其余两个恒 0。
     「黄光不爆闪」就是靠这个表保证的 —— 爆闪那一行只填 FN_SPOT。 */
  int  fnDuty[FN_COUNT] = { 0, 0, 0 };
  bool hardSwitch = false;      /* 爆闪要硬切，不能走渐变 */
  bool ignoreMask = false;      /* 爆闪无视掩码，4 组一起闪 */

  switch (sysMode) {
    case MODE_OFF:
      reason = "Off";
      break;

    case MODE_WHITE:
      fnDuty[FN_SPOT] = manualDuty;
      reason = "White";
      break;

    case MODE_DRL:
      fnDuty[FN_DRL] = DUTY_DRL;
      reason = "DRL";
      break;

    case MODE_AMBIENT:
      fnDuty[FN_AMB] = DUTY_AMBIENT;
      reason = "Ambient";
      break;

    case MODE_FLASH: {
      flashMs += TICK_MS;
      if (flashMs >= flashPattern[flashIdx].ms) {
        flashMs  = 0;
        flashIdx = (flashIdx + 1) % FLASH_STEPS;
      }
      fnDuty[FN_SPOT] = flashPattern[flashIdx].duty;
      hardSwitch = true;
      ignoreMask = true;        /* 警示灯要全车都看得见 */
      reason = "Flash";
      break;
    }

    default:
      break;
  }

  /* ---------- 3. 渐变 ---------- */
  for (uint8_t fn = 0; fn < FN_COUNT; fn++) {
    float target = (float)fnDuty[fn];
    if (hardSwitch) {
      curFn[fn] = target;
    } else {
      curFn[fn] += (target - curFn[fn]) * SMOOTH_FACTOR;
      if (fabsf(target - curFn[fn]) < 0.5f) curFn[fn] = target;
    }
  }

  /* ---------- 4. 按通道掩码输出 ---------- */
  for (uint8_t g = 0; g < GROUP_COUNT; g++) {
    for (uint8_t fn = 0; fn < FN_COUNT; fn++) {
      uint8_t ch  = CH_OF(g, fn);
      bool    on  = ignoreMask || (chMask & ((uint16_t)1 << ch));
      pcaSetChannelCached(ch, on ? (int)(curFn[fn] + 0.5f) : 0);
    }
    /* 每组第 4 路没接线，主动压 0，不让它悬空 */
    pcaSetChannelCached(CH_OF(g, FN_COUNT), 0);
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
  /* 有变化就报。爆闪时亮度每 50ms 就变一次，不能跟着报，
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
    Serial.printf("Mode:%s Mask:0x%04X BLE:%s Notify:%lu | Spot:%d%% DRL:%d%% Amb:%d%%\n",
                  reason,
                  chMask,
                  bleConnected ? "ON" : "--",
                  (unsigned long)notifyCount,
                  (int)(curFn[FN_SPOT] + 0.5f),
                  (int)(curFn[FN_DRL]  + 0.5f),
                  (int)(curFn[FN_AMB]  + 0.5f));
  }

  delay(TICK_MS);
}
