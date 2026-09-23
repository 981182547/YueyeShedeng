/*
 * 智能越野射灯控制器 2.0 —— ESP32-C3 / Arduino IDE 版（BLE 手机 + 语音）
 *
 * 这是 2.0（8 组灯）的固件，和 4 组版 smart_spotlight_ble、旧的 smart_spotlight_c3
 * 三者并存，互不影响。配套 App：offroad_light_8lutebieban。
 *
 * ── 灯组与通道 ─────────────────────────────────────────────
 * 8 组灯，编号和车图上标的一致。同一组的左右两只并联，受同一路控制。
 * 每组 3 个功能：白光（射灯）/ 日行灯 / 氛围灯（外圈黄光）。
 * 8 组 × 3 = 24 路。一片 PCA9685 只有 16 路，所以用两片：
 *
 *   PCA9685 0x40 —— 主灯 1~4 组        PCA9685 0x41 —— 辅助灯 5~8 组
 *
 * 每组占 4 路、用前 3 路，每组最后一路空着不接 —— 和 4 组版的接法规则一样。
 *
 *   编号 组号 灯组          分类     白光   日行   氛围   空      板子
 *   1    0    前杠灯        主灯     CH0    CH1    CH2    CH3     0x40
 *   2    1    A柱直射灯     主灯     CH4    CH5    CH6    CH7     0x40
 *   3    2    A柱侧位灯     主灯     CH8    CH9    CH10   CH11    0x40
 *   4    3    顶灯          主灯     CH12   CH13   CH14   CH15    0x40
 *   5    4    前杠内侧灯    辅助灯   CH16   CH17   CH18   CH19    0x41
 *   6    5    前杠外侧灯    辅助灯   CH20   CH21   CH22   CH23    0x41
 *   7    6    右侧灯        辅助灯   CH24   CH25   CH26   CH27    0x41
 *   8    7    左侧灯        辅助灯   CH28   CH29   CH30   CH31    0x41
 *
 *   通道号 = 组号 * 4 + 功能号（功能号 0=白光 1=日行 2=氛围）
 *   通道号 0~15 在 0x40 上，16~31 在 0x41 上（板上通道 = 通道号 % 16）
 *
 * ── 状态 = 通道掩码 + 两个"白光怎么亮"的修饰 ────────────────
 *   chMask    32 位，第 N 位 = CH N 现在亮不亮。就是输出，没有别的含义。
 *   flashMask 8 位，这几组的白光按节奏闪（爆闪）
 *   dimMask   8 位，这几组的白光只出 10%（主灯微亮）
 *   party     娱乐模式：8 组轮流爆闪，盖在上面显示；退出后原来的状态原样恢复
 *
 * 整组命令（语音「打开主灯日行」、App 上的主灯/辅助灯按钮）是一个【图章】：
 * 把这几组的 3 路连同修饰一起重设成目标状态 —— 每组同一时间只有一种状态，
 * 新命令直接替换旧的：
 *
 *   白光 -> 只开白光      日行 -> 只开日行      氛围 -> 只开氛围
 *   爆闪 -> 只开白光+闪   微亮 -> 日行 + 白光 10%   关闭 -> 3 路全灭
 *
 * App 分路控制页那 24 个开关是【最高权限】，一路一路直接改 chMask。
 * 【黄光不爆闪】依旧是结构上保证的：闪只作用在白光那一路。
 *
 * 任何灯光命令（整组、单路、掩码）都会先退出娱乐模式再执行。
 *
 * ── 上电默认 ──────────────────────────────────────────────
 * 主灯 1~4 组日行灯亮，辅助灯 5~8 组不亮。模式和通道不做掉电记忆，
 * 每次点火都是这个样子；只有白光亮度存 NVS。
 *
 * ── 语音（CI1302 / ASR PRO）─────────────────────────────────
 * 串口一行一条：$<灯组>:<动作>\r\n，协议见 asr_pro/asr_pro_voice.cpp。
 * 按冒号拆开、两段各自【整串比对】—— 不能用 strstr，
 * 否则 PARTY 会误匹配到 PARTY_OFF。
 *
 * ── 硬件连接 ───────────────────────────────────────────────
 *   IO4  -> 两片 PCA9685 的 SDA（并在一起）
 *   IO5  -> 两片 PCA9685 的 SCL（并在一起）
 *   第二片 PCA9685 把 A0 焊到高电平，地址就是 0x41
 *   IO2  <- CI1302 TX          IO3  -> CI1302 RX
 *
 * ── Arduino IDE 设置 ───────────────────────────────────────
 *   开发板   : ESP32C3 Dev Module
 *   USB CDC On Boot : Enabled
 *   Partition Scheme: 选带 OTA 或 Huge APP 的方案（BLE 协议栈较大，Default 可能装不下）
 *   依赖库   : 全部为 ESP32 Arduino Core 自带，无需额外安装
 */

#include <Wire.h>
#include <math.h>
#include <string.h>
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

#define PCA_ADDR_MAIN    0x40   /* 主灯 1~4 组 */
#define PCA_ADDR_AUX     0x41   /* 辅助灯 5~8 组 */
#define PCA_BOARDS       2
#define PCA_CH_PER_BOARD 16
#define PCA9685_FREQ_HZ  1000
#define I2C_SPEED_HZ     400000

static const uint8_t pcaAddr[PCA_BOARDS] = { PCA_ADDR_MAIN, PCA_ADDR_AUX };

/* ── 灯组与通道映射 ──────────────────────────────────────
 * 改接线只要改这几个常量，输出级不用动。 */
#define GROUP_COUNT      8       /* 8 组灯 */
#define CH_PER_GROUP     4       /* 接线板 4 路一组，用前 3 路 */
#define FN_COUNT         3       /* 每组 3 个功能 */
#define FN_SPOT          0       /* 白光（射灯） */
#define FN_DRL           1       /* 日行灯 */
#define FN_AMB           2       /* 氛围灯（外圈黄光） */
#define CH_TOTAL         (GROUP_COUNT * CH_PER_GROUP)   /* 32 */

/* 组号 + 功能号 -> 通道号 0~31 */
#define CH_OF(g, fn)     ((uint8_t)((g) * CH_PER_GROUP + (fn)))
#define CH_BIT(ch)       ((uint32_t)1 << (ch))
#define GROUP_BITS(g)    ((uint32_t)0x7 << ((g) * CH_PER_GROUP))

/* 每组低 3 位置 1、第 4 位(空通道)置 0 */
#define CH_MASK_ALL      0x77777777UL

#define GROUPS_MAIN      0x0F    /* 主灯：组 0~3（编号 1~4） */
#define GROUPS_AUX       0xF0    /* 辅助灯：组 4~7（编号 5~8） */
#define GROUPS_ALL       0xFF

#define TICK_MS          10      /* 主循环周期 */
#define SMOOTH_FACTOR    0.06f   /* 亮度渐变系数，越小越柔和 */

/* 日行灯和氛围灯不调亮度，直接给满 ——
 * 那些灯珠本身就比射灯暗得多，再降就基本看不见了。 */
#define DUTY_DRL         100     /* 日行灯亮度（固定，不跟滑条） */
#define DUTY_AMBIENT     100     /* 氛围灯亮度（固定，不跟滑条） */
#define DUTY_DIM         10      /* 主灯微亮时白光那一路的亮度 */

#define FW_VERSION       20      /* 协议版本，随状态一起上报。20 = 2.0。
                                    4 组版固件是 3，两条产品线的版本号故意岔开 ——
                                    烧错了固件 App 会直接报版本不匹配。
                                    改了封包格式【或者改了状态的语义】就必须 +1。 */

HardwareSerial ASR(1);           /* 用 UART1，避开 USB CDC 日志 */
Preferences    prefs;            /* NVS：只记亮度 */

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
#define OP_CH_MASK       0x11    /* [b3,b2,b1,b0]     一次设置 32 位通道掩码 */
#define OP_CH            0x12    /* [ch, on]          单个通道开关 */
#define OP_BRIGHT        0x14    /* [duty 0~100]      白光亮度 */
#define OP_QUERY         0x15    /* []                请求上报当前状态 */
#define OP_GROUP_SET     0x16    /* [groups, action]  给这几组盖图章（bit g = 组 g） */
#define OP_PARTY         0x17    /* [on]              娱乐模式开/关 */

/* 设备 -> App（Notify）
 * [party, flashMask, dimMask, bright, ver, m3, m2, m1, m0]
 * 版本号放在第 4 个字节，和 4 组版的状态包同一个位置 ——
 * 两边的 App 连错了固件都能读到对方的版本号，直接报不匹配。 */
#define OP_STATUS        0x20
#define STATUS_LEN       9

/* 整组动作。必须和 App 的 GroupAct 一致。 */
enum GroupAct {
  ACT_OFF   = 0,   /* 3 路全灭 */
  ACT_WHITE = 1,   /* 只开白光 */
  ACT_DRL   = 2,   /* 只开日行 */
  ACT_AMB   = 3,   /* 只开氛围 */
  ACT_FLASH = 4,   /* 只开白光，并按节奏闪 */
  ACT_DIM   = 5,   /* 日行 + 白光 10%（主灯微亮） */
  ACT_MAX
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

static void pcaWrite(uint8_t addr, uint8_t reg, uint8_t val) {
  Wire.beginTransmission(addr);
  Wire.write(reg);
  Wire.write(val);
  Wire.endTransmission();
}

static void pcaWriteLed(uint8_t addr, uint8_t ch, uint16_t on, uint16_t off) {
  Wire.beginTransmission(addr);
  Wire.write(PCA_LED0_ON_L + 4 * ch);
  Wire.write(on  & 0xFF);
  Wire.write(on  >> 8);
  Wire.write(off & 0xFF);
  Wire.write(off >> 8);
  Wire.endTransmission();
}

/* 这个地址上有没有板子应答。只用于开机自检打印。 */
static bool pcaPresent(uint8_t addr) {
  Wire.beginTransmission(addr);
  return Wire.endTransmission() == 0;
}

static void pcaInitBoard(uint8_t addr, uint32_t freqHz) {
  pcaWrite(addr, PCA_MODE1, MODE1_SLEEP);        /* 睡眠态才能改 PRESCALE */
  delay(1);

  uint8_t prescale = (uint8_t)(roundf(25000000.0f / (4096.0f * freqHz)) - 1);
  pcaWrite(addr, PCA_PRESCALE, prescale);
  delay(1);

  pcaWrite(addr, PCA_MODE1, MODE1_AI | MODE1_ALLCALL);
  delay(1);
  pcaWrite(addr, PCA_MODE1, MODE1_RESTART | MODE1_AI | MODE1_ALLCALL);
  pcaWrite(addr, PCA_MODE2, 0x04);               /* OUTDRV = 推挽 */
  delay(1);

  for (uint8_t ch = 0; ch < PCA_CH_PER_BOARD; ch++) pcaWriteLed(addr, ch, 0, 0x1000);
}

static void pca9685Init(uint32_t freqHz) {
  Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL, I2C_SPEED_HZ);
  for (uint8_t b = 0; b < PCA_BOARDS; b++) {
    bool ok = pcaPresent(pcaAddr[b]);
    pcaInitBoard(pcaAddr[b], freqHz);
    Serial.printf("[init] PCA9685 0x%02X (%s): %s\n", pcaAddr[b],
                  b == 0 ? "主灯 1~4 组" : "辅助灯 5~8 组",
                  ok ? "就绪" : "未应答！检查接线 / 地址跳线");
  }
}

/* 设置单个通道占空比 0~100%。ch 是全局通道号 0~31，自动分到对应的板子。
 * on 相位按板上通道号错开，多路同时点亮时电源尖峰会小很多。 */
static void pcaSetChannel(uint8_t ch, int duty) {
  uint8_t addr = pcaAddr[ch / PCA_CH_PER_BOARD];
  uint8_t bch  = ch % PCA_CH_PER_BOARD;
  if (duty < 0)   duty = 0;
  if (duty > 100) duty = 100;
  if (duty == 0) {
    pcaWriteLed(addr, bch, 0, 0x1000);           /* full OFF */
  } else if (duty == 100) {
    pcaWriteLed(addr, bch, 0x1000, 0);           /* full ON  */
  } else {
    uint16_t on  = (uint16_t)(bch * 256) & 0x0FFF;
    uint16_t len = (uint16_t)(duty * 4096 / 100);
    uint16_t off = (on + len) & 0x0FFF;
    pcaWriteLed(addr, bch, on, off);
  }
}

/* 只在数值变化时才刷 I2C，避免每个 tick 都写满 32 路把总线占死 */
static int lastDuty[CH_TOTAL];

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
 * 想改快慢/闪几下，只动这张表就行 —— App 的车图动画照抄这张表 */
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

/* 娱乐模式：按这个顺序一组一组地闪，每组「亮-灭-亮-灭」各 PARTY_STEP_MS。
 * 顺序就是车图上的编号 1→8。App 的车图动画照抄这两个常量。 */
static const uint8_t partyOrder[GROUP_COUNT] = { 0, 1, 2, 3, 4, 5, 6, 7 };
#define PARTY_STEP_MS    60
#define PARTY_STEPS_PER_GROUP 4

static uint32_t chMask     = 0;                /* bit N = CH N 现在亮不亮 */
static uint8_t  flashMask  = 0;                /* 这几组的白光在爆闪 */
static uint8_t  dimMask    = 0;                /* 这几组的白光只出 10% */
static bool     party      = false;            /* 娱乐模式 */
static uint8_t  manualDuty = 100;              /* 白光亮度 */

/* 每一路各自渐变中的实际亮度 */
static float curCh[CH_TOTAL] = { 0 };

static uint32_t flashIdx = 0, flashMs = 0, partyMs = 0, logMs = 0;

/* 状态有变化时置位，下一个 tick 统一上报（避免一次操作发好几包） */
static bool     statusDirty = true;
static uint32_t statusMs    = 0;

/* ==========================================================
 * 五、NVS 掉电记忆
 *
 * 只记亮度 —— 模式和通道故意不记，点火后一律是「主灯日行、辅助灯灭」。
 * 只在值真的变了的时候写，NVS 有擦写寿命，别每个 tick 都写。
 * ========================================================== */
static void saveSettings() {
  prefs.putUChar("duty", manualDuty);
  Serial.printf("[NVS] 已保存 duty=%u\n", manualDuty);
}

static void loadSettings() {
  prefs.begin("spotlight", false);
  manualDuty = prefs.getUChar("duty", 100);
  if (manualDuty > 100) manualDuty = 100;
  Serial.printf("[NVS] 已恢复 duty=%u\n", manualDuty);
}

/* NVS 延迟写入：变化停下来之后才落盘 */
static bool     savePending = false;
static uint32_t saveTimer   = 0;

/* 标记状态已变化：下个 tick 上报，并排队一次存盘。
 * 只有亮度需要 persist=true，模式和通道都不记忆。 */
static void markDirty(bool persist = false) {
  statusDirty = true;
  if (persist) {
    savePending = true;
    saveTimer   = 0;      /* 每来一次新变化就重新计时 */
  }
}

/* ==========================================================
 * 六、灯光操作（BLE 和语音共用同一套入口）
 * ========================================================== */
static const char *actName(uint8_t act) {
  switch (act) {
    case ACT_OFF:   return "关闭";
    case ACT_WHITE: return "白光";
    case ACT_DRL:   return "日行";
    case ACT_AMB:   return "氛围";
    case ACT_FLASH: return "爆闪";
    case ACT_DIM:   return "微亮";
    default:        return "?";
  }
}

/* 退出娱乐模式。任何灯光命令执行前都先调它 ——
 * 娱乐模式只是盖在上面显示的，底下的状态一直没动，退出就原样恢复。 */
static void leaveParty() {
  if (party) {
    party = false;
    Serial.println("[灯] 退出娱乐模式");
  }
}

/* 白光被关掉的组，爆闪/微亮的修饰也一起清掉 ——
 * 修饰说的是"白光怎么亮"，白光都灭了它就没意义了；
 * 不清的话下次在分路页单独点亮白光，会莫名其妙地闪或者只亮 10%。 */
static void dropOrphanModifiers() {
  for (uint8_t g = 0; g < GROUP_COUNT; g++) {
    if (!(chMask & CH_BIT(CH_OF(g, FN_SPOT)))) {
      flashMask &= ~(uint8_t)(1 << g);
      dimMask   &= ~(uint8_t)(1 << g);
    }
  }
}

/* 给这几组盖图章：3 路连同修饰一起重设，每组同一时间只有一种状态。 */
static void applyGroups(uint8_t groups, uint8_t act, const char *who) {
  if (act >= ACT_MAX) return;
  leaveParty();
  bool addFlash = false;
  for (uint8_t g = 0; g < GROUP_COUNT; g++) {
    if (!(groups & (1 << g))) continue;
    uint8_t gb = (uint8_t)(1 << g);
    chMask    &= ~GROUP_BITS(g);
    flashMask &= ~gb;
    dimMask   &= ~gb;
    switch (act) {
      case ACT_WHITE: chMask |= CH_BIT(CH_OF(g, FN_SPOT)); break;
      case ACT_DRL:   chMask |= CH_BIT(CH_OF(g, FN_DRL));  break;
      case ACT_AMB:   chMask |= CH_BIT(CH_OF(g, FN_AMB));  break;
      case ACT_FLASH:
        chMask |= CH_BIT(CH_OF(g, FN_SPOT));
        flashMask |= gb;
        addFlash = true;
        break;
      case ACT_DIM:
        chMask |= CH_BIT(CH_OF(g, FN_SPOT)) | CH_BIT(CH_OF(g, FN_DRL));
        dimMask |= gb;
        break;
      default: break;                              /* ACT_OFF：全灭 */
    }
  }
  /* 有组新加入爆闪就把节奏从头开始，所有在闪的组保持同步 */
  if (addFlash) { flashIdx = 0; flashMs = 0; }
  Serial.printf("[灯] %s: 组 0x%02X -> %s  掩码 0x%08lX\n",
                who, groups, actName(act), (unsigned long)chMask);
  markDirty();
}

/* 换掩码的统一入口（分路控制页用）：空通道那几位永远清掉 */
static void applyMask(uint32_t next, const char *who) {
  leaveParty();
  next &= CH_MASK_ALL;
  chMask = next;
  dropOrphanModifiers();
  Serial.printf("[灯] %s -> 掩码 0x%08lX\n", who, (unsigned long)chMask);
  markDirty();
}

static void setParty(bool on, const char *who) {
  if (on == party) return;
  party = on;
  partyMs = 0;
  Serial.printf("[灯] %s: 娱乐模式 %s\n", who, on ? "开" : "关");
  markDirty();
}

/* 开机状态：主灯日行，辅助灯灭 */
static void applyBootState() {
  chMask = 0; flashMask = 0; dimMask = 0; party = false;
  applyGroups(GROUPS_MAIN, ACT_DRL, "开机");
}

/* ==========================================================
 * 七、BLE 服务端
 * ========================================================== */
static BLEServer         *bleServer = nullptr;
static BLECharacteristic *txChar    = nullptr;
static bool               bleConnected = false;

/* 累计发出去多少帧状态。串口每秒打印它 ——
 * 排查「语音改了灯、手机没跟着变」时，先看这个数字动没动：
 *   不动  = 固件没发（没连上，或者 txChar 没建起来）
 *   在涨但手机没反应 = 帧发出去了，问题在手机那边没订阅上 */
static uint32_t notifyCount = 0;

/* 把当前状态打包成一帧 0xA5 上报给手机 */
static void notifyStatus() {
  if (!bleConnected || txChar == nullptr) return;

  uint8_t pkt[4 + STATUS_LEN];
  pkt[0]  = PKT_MAGIC;
  pkt[1]  = OP_STATUS;
  pkt[2]  = 0;
  pkt[3]  = STATUS_LEN;
  pkt[4]  = party ? 1 : 0;
  pkt[5]  = flashMask;
  pkt[6]  = dimMask;
  pkt[7]  = manualDuty;
  pkt[8]  = FW_VERSION;
  pkt[9]  = (uint8_t)(chMask >> 24);
  pkt[10] = (uint8_t)(chMask >> 16);
  pkt[11] = (uint8_t)(chMask >> 8);
  pkt[12] = (uint8_t)(chMask & 0xFF);

  txChar->setValue(pkt, sizeof(pkt));
  txChar->notify();
  notifyCount++;
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

/* 解析 App 发来的封包 */
static void handlePacket(uint8_t op, const uint8_t *data, size_t len) {
  switch (op) {
    case OP_GROUP_SET: {
      if (len < 2) return;
      /* 就算已经是这个状态也照盖一次 —— 分路页手动改花了之后，
         再点一下同一个按钮就能一键复位 */
      applyGroups(data[0], data[1], "App");
      break;
    }
    case OP_CH_MASK: {
      if (len < 4) return;
      uint32_t m = ((uint32_t)data[0] << 24) | ((uint32_t)data[1] << 16) |
                   ((uint32_t)data[2] << 8)  |  (uint32_t)data[3];
      applyMask(m, "通道掩码");
      break;
    }
    case OP_CH: {
      if (len < 2) return;
      uint8_t ch = data[0];
      if (ch >= CH_TOTAL) return;
      applyMask(data[1] ? (chMask | CH_BIT(ch)) : (chMask & ~CH_BIT(ch)), "单通道");
      break;
    }
    case OP_PARTY: {
      if (len < 1) return;
      setParty(data[0] != 0, "App");
      break;
    }
    case OP_BRIGHT: {
      if (len < 1) return;
      uint8_t d = data[0] > 100 ? 100 : data[0];
      if (manualDuty != d) {
        manualDuty = d;
        Serial.printf("[BLE] 亮度: %u%%\n", manualDuty);
        markDirty(true);                 /* 只有亮度进 NVS */
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
 * 八、语音指令：$<灯组>:<动作>\r\n
 * ========================================================== */
struct GroupCode { const char *code; uint8_t groups; };
static const GroupCode groupCodes[] = {
  { "BMP",  1 << 0 },   /* 1 前杠灯 */
  { "APD",  1 << 1 },   /* 2 A柱直射灯 */
  { "APS",  1 << 2 },   /* 3 A柱侧位灯 */
  { "ROF",  1 << 3 },   /* 4 顶灯 */
  { "BMI",  1 << 4 },   /* 5 前杠内侧灯 */
  { "BMO",  1 << 5 },   /* 6 前杠外侧灯 */
  { "RGT",  1 << 6 },   /* 7 右侧灯 */
  { "LFT",  1 << 7 },   /* 8 左侧灯 */
  { "MAIN", GROUPS_MAIN },
  { "AUX",  GROUPS_AUX },
  { "ALL",  GROUPS_ALL },
};

struct ActCode { const char *code; uint8_t act; };
static const ActCode actCodes[] = {
  { "OFF",   ACT_OFF   },
  { "ON",    ACT_WHITE },
  { "DRL",   ACT_DRL   },
  { "AMB",   ACT_AMB   },
  { "FLASH", ACT_FLASH },
  { "DIM",   ACT_DIM   },
};

#define COUNT_OF(a) (sizeof(a) / sizeof((a)[0]))

/* 处理一整行。行首必须是 $，其余的一律当噪声丢掉 ——
 * 语音模块开机时串口上可能还有它自己的打印。 */
static void handleVoiceLine(char *line) {
  if (line[0] != '$') return;
  char *grp = line + 1;
  char *act = strchr(grp, ':');
  if (act == nullptr) {
    Serial.printf("[语音] 格式不对，忽略: %s\n", line);
    return;
  }
  *act++ = '\0';

  /* 娱乐模式和全车关闭是 ALL 专属的，单独处理 */
  if (strcmp(grp, "ALL") == 0) {
    if (strcmp(act, "PARTY") == 0)     { setParty(true,  "语音"); return; }
    if (strcmp(act, "PARTY_OFF") == 0) { setParty(false, "语音"); return; }
  }

  uint8_t groups = 0;
  for (size_t i = 0; i < COUNT_OF(groupCodes); i++) {
    if (strcmp(grp, groupCodes[i].code) == 0) { groups = groupCodes[i].groups; break; }
  }
  int a = -1;
  for (size_t i = 0; i < COUNT_OF(actCodes); i++) {
    if (strcmp(act, actCodes[i].code) == 0) { a = actCodes[i].act; break; }
  }
  if (groups == 0 || a < 0) {
    Serial.printf("[语音] 不认识的指令，忽略: $%s:%s\n", grp, act);
    return;
  }
  applyGroups(groups, (uint8_t)a, "语音");
}

/* 攒字节，攒到换行就处理一行。不能按"一次 available 读完"来切 ——
 * 串口一帧可能分两次到，也可能两条指令粘在一起。 */
static char     voiceBuf[48];
static uint8_t  voiceLen = 0;

static void pollVoice() {
  while (ASR.available()) {
    char c = (char)ASR.read();
    if (c == '\r') continue;
    if (c == '\n') {
      voiceBuf[voiceLen] = '\0';
      if (voiceLen > 0) {
        Serial.printf("[语音] 收到: %s\n", voiceBuf);
        handleVoiceLine(voiceBuf);
      }
      voiceLen = 0;
      continue;
    }
    if (c == '$') voiceLen = 0;          /* 新指令开头：前面残缺的半截丢掉 */
    if (voiceLen < sizeof(voiceBuf) - 1) voiceBuf[voiceLen++] = c;
    else voiceLen = 0;                   /* 超长 = 乱码，整行作废 */
  }
}

/* ==========================================================
 * 九、setup / loop
 * ========================================================== */
void setup() {
  Serial.begin(115200);                          /* USB CDC 日志 */
  ASR.begin(ASR_BAUD, SERIAL_8N1, PIN_ASR_RX, PIN_ASR_TX);

  for (uint8_t ch = 0; ch < CH_TOTAL; ch++) lastDuty[ch] = -1;

  loadSettings();                                /* 只恢复亮度 */
  pca9685Init(PCA9685_FREQ_HZ);
  applyBootState();                              /* 主灯日行，辅助灯灭 */
  bleInit();

  Serial.println("[init] 系统启动完毕  FW=2.0（8 组）  上电：主灯日行、辅助灯灭");
}

/* 这一组的白光这会儿该出多少 */
static int spotDuty(uint8_t g, int flashDuty) {
  uint8_t gb = (uint8_t)(1 << g);
  if (flashMask & gb) return flashDuty;
  if (dimMask & gb)   return DUTY_DIM;
  return manualDuty;
}

void loop() {
  /* ---------- 1. 语音指令 ---------- */
  pollVoice();

  /* ---------- 2. 爆闪 / 娱乐模式节奏 ---------- */
  int flashDuty = 0;
  if (flashMask) {
    flashMs += TICK_MS;
    if (flashMs >= flashPattern[flashIdx].ms) {
      flashMs  = 0;
      flashIdx = (flashIdx + 1) % FLASH_STEPS;
    }
    flashDuty = flashPattern[flashIdx].duty;
  }

  int partyGroup = -1;                           /* 娱乐模式下这会儿亮哪一组 */
  if (party) {
    partyMs += TICK_MS;
    uint32_t step = partyMs / PARTY_STEP_MS;
    uint32_t cycle = (uint32_t)GROUP_COUNT * PARTY_STEPS_PER_GROUP;
    if (step >= cycle) { partyMs %= cycle * PARTY_STEP_MS; step %= cycle; }
    /* 每组内部是 亮-灭-亮-灭：偶数步亮 */
    if ((step % PARTY_STEPS_PER_GROUP) % 2 == 0) {
      partyGroup = partyOrder[step / PARTY_STEPS_PER_GROUP];
    }
  }

  /* ---------- 3. 逐路输出 ---------- */
  for (uint8_t g = 0; g < GROUP_COUNT; g++) {
    for (uint8_t fn = 0; fn < FN_COUNT; fn++) {
      uint8_t ch = CH_OF(g, fn);

      if (party) {
        /* 娱乐模式盖在上面：只有轮到的那一组白光亮，其余全灭，硬切 */
        curCh[ch] = (fn == FN_SPOT && g == partyGroup) ? 100.0f : 0.0f;
        pcaSetChannelCached(ch, (int)curCh[ch]);
        continue;
      }

      bool on = chMask & CH_BIT(ch);
      int duty;
      switch (fn) {
        case FN_SPOT: duty = spotDuty(g, flashDuty); break;
        case FN_DRL:  duty = DUTY_DRL;               break;
        default:      duty = DUTY_AMBIENT;           break;
      }
      float target = on ? (float)duty : 0.0f;

      /* 爆闪要硬切，不能走渐变；其余一律渐变，切换时柔和些 */
      if (on && fn == FN_SPOT && (flashMask & (1 << g))) {
        curCh[ch] = target;
      } else {
        curCh[ch] += (target - curCh[ch]) * SMOOTH_FACTOR;
        if (fabsf(target - curCh[ch]) < 0.5f) curCh[ch] = target;
      }
      pcaSetChannelCached(ch, (int)(curCh[ch] + 0.5f));
    }
    /* 每组第 4 路没接线，主动压 0，不让它悬空 */
    pcaSetChannelCached(CH_OF(g, FN_COUNT), 0);
  }

  /* ---------- 4. NVS 延迟落盘 ---------- */
  if (savePending) {
    saveTimer += TICK_MS;
    if (saveTimer >= 2000) {          /* 2 秒内没有新变化才写 */
      saveSettings();
      savePending = false;
      saveTimer   = 0;
    }
  }

  /* ---------- 5. 状态上报 ---------- */
  /* 只报"设置"层面的变化，不报爆闪、娱乐模式的瞬时亮度 */
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

  /* ---------- 6. 串口状态打印（每 1s） ---------- */
  logMs += TICK_MS;
  if (logMs >= 1000) {
    logMs = 0;
    Serial.printf("Mask:0x%08lX Flash:0x%02X Dim:0x%02X Party:%s Duty:%u%% BLE:%s Notify:%lu |",
                  (unsigned long)chMask, flashMask, dimMask, party ? "ON" : "--",
                  manualDuty, bleConnected ? "ON" : "--",
                  (unsigned long)notifyCount);
    /* 按车图编号打印每组 白/日行/氛围 的实际占空比 */
    for (uint8_t g = 0; g < GROUP_COUNT; g++) {
      Serial.printf(" %u[%d/%d/%d]", g + 1,
                    (int)(curCh[CH_OF(g, FN_SPOT)] + 0.5f),
                    (int)(curCh[CH_OF(g, FN_DRL)]  + 0.5f),
                    (int)(curCh[CH_OF(g, FN_AMB)]  + 0.5f));
    }
    Serial.println();
  }

  delay(TICK_MS);
}
