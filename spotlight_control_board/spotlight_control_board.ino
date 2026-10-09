/*
 * 越野射灯 —— 控制板（前舱） ESP32-C3 / Arduino IDE 版（BLE 手机 + ESP-NOW 语音）
 *
 * 两块板的方案：驾驶室的语音板收 CI1302 的指令，通过 ESP-NOW 转到这块板；
 * 这块板驱动两片 PCA9685，同时用蓝牙连手机。配套语音板：spotlight_voice_board；
 * 配套 App：offroad_light_8lutebieban（和 2.0 同一个协议，App 不用改）。
 *
 * 由 smart_spotlight_v2 改来 —— 灯光逻辑一模一样，只是语音从串口换成了 ESP-NOW。
 * smart_spotlight_v2、4 组版 smart_spotlight_ble、旧的 smart_spotlight_c3 都还在，互不影响。
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
 * ── 语音：从驾驶室的语音板经 ESP-NOW 过来 ─────────────────────
 * 语音板把 CI1302 发的 "$BMP:ON" 原样转过来（协议、配对规则见 spotlight_link.h），
 * 这里补回 $ 交给 handleVoiceLine() —— 和以前直接接串口时是同一段代码。
 * 按冒号拆开、两段各自【整串比对】—— 不能用 strstr，否则 PARTY 会误匹配到 PARTY_OFF。
 *
 * 配对：长按 BOOT 3 秒（语音板那边也要长按），30 秒内两边都按下就配上。
 * 状态灯：配对中快闪，连上常亮，没连上慢闪。
 *
 * ── 硬件连接（引脚定义在 board_pins.h）─────────────────────────
 *   IO4 / IO5 -> 两片 PCA9685 的 SDA / SCL（并在一起，板上 4.7k 上拉）
 *   IO6       -> 两片 PCA9685 的 OE，低电平使能。板上有上拉，上电默认关输出；
 *                固件初始化完、开机状态写好之后才拉低 —— 上电那一下不会乱闪
 *   IO7       -> 状态灯（高电平亮）        IO9 -> BOOT 键（长按 3 秒配对）
 *   第二片 PCA9685 把 A0 焊到高电平，地址就是 0x41
 *
 * ── 只接一片也行 ───────────────────────────────────────────
 * 哪片板子管哪 4 组，由它的【地址】决定，跟接在哪根线上无关：
 *   A0 不焊 = 0x40 = 主灯 1~4 组        A0 焊上 = 0x41 = 辅助灯 5~8 组
 * 只装主灯就只接 0x40，只装辅助灯就只接 0x41，两片都接就 8 组全有。
 *
 * 固件每 2 秒探测一次两个地址：
 *   - 没接的板子不往它写，免得每次都在总线上等一个 NACK、把爆闪节奏拖慢；
 *   - 板子后上电、或者掉电复位了（MODE1 里 SLEEP 位又变回 1），
 *     探测到就重新初始化，并按当前状态把它那 16 路重写一遍。
 * 哪片在线也随状态一起报给 App，没接的那几组在界面上是灰的；
 * 娱乐模式也只在接了的组之间轮流闪。
 *
 * ── Arduino IDE 设置 ───────────────────────────────────────
 *   开发板   : ESP32C3 Dev Module
 *   USB CDC On Boot : Enabled
 *   Partition Scheme: Huge APP (3MB No OTA) —— 蓝牙加 WiFi 一起，Default 装不下
 *   ESP32 核心 : 3.x（和语音板、遥控小车同一个环境）
 *   依赖库   : 全部为 ESP32 Arduino Core 自带，无需额外安装
 */

#define BOARD_CONTROL
#include "board_pins.h"
#include "spotlight_link.h"

#include <Wire.h>
#include <math.h>
#include <string.h>
#include <Preferences.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <WiFi.h>
#include <esp_wifi.h>
#include <esp_now.h>

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
/* 引脚（I2C、OE、状态灯、BOOT）都在 board_pins.h 里 */

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
 * [party, flashMask, dimMask, bright, ver, m3, m2, m1, m0, boards]
 * 版本号放在第 4 个字节，和 4 组版的状态包同一个位置 ——
 * 两边的 App 连错了固件都能读到对方的版本号，直接报不匹配。
 * boards：bit0 = 0x40 主灯板在线，bit1 = 0x41 辅助灯板在线。 */
#define OP_STATUS        0x20
#define STATUS_LEN       10

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

/* 读一个寄存器。板子不在（没应答）返回 -1 —— 探测在不在线就靠它。 */
static int pcaRead(uint8_t addr, uint8_t reg) {
  Wire.beginTransmission(addr);
  Wire.write(reg);
  if (Wire.endTransmission() != 0) return -1;
  if (Wire.requestFrom(addr, (uint8_t)1) != 1) return -1;
  return Wire.read();
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

/* 哪片板子现在在线。没接的板子一律不写 —— 见文件头「只接一片也行」 */
static bool pcaOk[PCA_BOARDS] = { false, false };

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
  if (!pcaOk[ch / PCA_CH_PER_BOARD]) return;     /* 这片没接，不写 */
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

/* 探测两片 PCA9685 在不在线。开机调一次，之后每 2 秒一次。
 *
 * 读 MODE1 寄存器：读不到 = 没接；读到了但 SLEEP 位是 1 = 刚上电或者掉电复位过
 * （初始化之后 SLEEP 一直是 0）。这两种"从不可用变成可用"的情况都要重新初始化，
 * 再把这片 16 路的缓存作废 —— 下一个 tick 就会按当前状态整片重写一遍。 */
#define PROBE_MS         2000
static uint32_t probeMs = 0;

static void pcaProbe() {
  for (uint8_t b = 0; b < PCA_BOARDS; b++) {
    int  mode1 = pcaRead(pcaAddr[b], PCA_MODE1);
    bool now   = mode1 >= 0;
    const char *role = (b == 0) ? "主灯 1~4 组" : "辅助灯 5~8 组";

    if (now && (!pcaOk[b] || (mode1 & MODE1_SLEEP))) {
      pcaInitBoard(pcaAddr[b], PCA9685_FREQ_HZ);
      for (uint8_t i = 0; i < PCA_CH_PER_BOARD; i++) {
        lastDuty[b * PCA_CH_PER_BOARD + i] = -1;
      }
      Serial.printf("[PCA] 0x%02X（%s）%s\n", pcaAddr[b], role,
                    pcaOk[b] ? "复位过，已重新初始化" : "在线，已初始化");
    } else if (!now && pcaOk[b]) {
      Serial.printf("[PCA] 0x%02X（%s）掉线了\n", pcaAddr[b], role);
    } else if (!now && probeMs == 0) {
      Serial.printf("[PCA] 0x%02X（%s）没接\n", pcaAddr[b], role);
    }

    if (now != pcaOk[b]) markDirty();            /* 在线情况变了，报给 App */
    pcaOk[b] = now;
  }
}

/* 这一组的板子在不在线 */
static bool groupPresent(uint8_t g) {
  return pcaOk[CH_OF(g, 0) / PCA_CH_PER_BOARD];
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
  pkt[13] = (pcaOk[0] ? 0x01 : 0) | (pcaOk[1] ? 0x02 : 0);

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

/* ==========================================================
 * 八点五、ESP-NOW：语音板过来的指令 + 配对 + 状态灯
 *
 * 规则见 spotlight_link.h。ESP-NOW 回调跑在 WiFi 任务里，只做核对和排队；
 * 执行指令、存 MAC、加 peer 都放在 loop 里做 —— 回调里写 Flash 容易出问题。
 * ========================================================== */
static Preferences linkPrefs;              /* 单独一个，别和存亮度的 prefs 抢 */
static uint8_t  linkPeer[6];               /* 语音板 MAC */
static bool     linkPaired = false;
static volatile bool     linkPairing = false;
static uint32_t linkPairingSince = 0;
static volatile uint32_t lastLinkMs = 0;   /* 最近一次收到语音板的包 */
static volatile bool     gotPairReq = false;
static uint8_t  pairReqMac[6];
static bool     outputsEnabled = false;    /* OE 拉低了没有 */

static portMUX_TYPE linkMux = portMUX_INITIALIZER_UNLOCKED;

struct RxCmd { uint8_t seq; uint8_t len; char text[LINK_TEXT_MAX]; };
static QueueHandle_t rxQ = nullptr;

/* 去重：语音板没收到硬件应答会重发同一条（序号不变），2 秒内同一个序号只执行一次 */
static int      lastSeq   = -1;
static uint32_t lastSeqMs = 0;

static void printMac(const char *label, const uint8_t *m) {
  Serial.printf("%s%02X:%02X:%02X:%02X:%02X:%02X\n", label, m[0], m[1], m[2], m[3], m[4], m[5]);
}

static void linkOnRecv(LINK_RECV_CB_ARGS) {
  if (len != (int)sizeof(LinkPkt)) return;
  const LinkPkt *p = (const LinkPkt *)data;
  if (p->magic != LINK_MAGIC) return;
  const uint8_t *src = LINK_RECV_SRC;

  portENTER_CRITICAL(&linkMux);
  bool fromPeer = linkPaired && memcmp(src, linkPeer, 6) == 0;
  portEXIT_CRITICAL(&linkMux);

  switch (p->type) {
    case LINK_PAIR_REQ:
      /* 配对模式下谁来都接。不在配对模式时只理已经配上的那块 ——
         它还在发配对请求，说明它没收到上次的 PAIR_ACK，给它补发一个 */
      if ((linkPairing || fromPeer) && !gotPairReq) {
        memcpy(pairReqMac, src, 6);
        gotPairReq = true;
      }
      break;
    case LINK_PING:
      if (fromPeer) lastLinkMs = millis();
      break;
    case LINK_CMD:
      if (fromPeer && p->len > 0 && p->len < LINK_TEXT_MAX && rxQ != nullptr) {
        lastLinkMs = millis();
        RxCmd c;
        c.seq = p->seq;
        c.len = p->len;
        memcpy(c.text, p->text, p->len);
        xQueueSend(rxQ, &c, 0);
      }
      break;
    default:
      break;
  }
}

static void linkAddPeer(const uint8_t *mac) {
  if (esp_now_is_peer_exist(mac)) return;
  esp_now_peer_info_t info = {};
  memcpy(info.peer_addr, mac, 6);
  info.channel = LINK_CHANNEL;
  info.encrypt = false;
  esp_now_add_peer(&info);
}

static void linkSendPairAck(const uint8_t *mac) {
  linkAddPeer(mac);
  LinkPkt p = {};
  p.magic = LINK_MAGIC;
  p.type  = LINK_PAIR_ACK;
  esp_now_send(mac, (const uint8_t *)&p, sizeof(p));
}

static void linkInit() {
  rxQ = xQueueCreate(8, sizeof(RxCmd));

  WiFi.mode(WIFI_STA);
  /* 这块板同时跑蓝牙：WiFi 必须留在默认的 modem sleep ——
     设成 WIFI_PS_NONE 在 WiFi 和蓝牙共存时会报错。ESP-NOW 照样收得到。 */
  esp_wifi_set_max_tx_power(78);              /* 19.5 dBm */
  esp_wifi_set_promiscuous(true);
  esp_wifi_set_channel(LINK_CHANNEL, WIFI_SECOND_CHAN_NONE);
  esp_wifi_set_promiscuous(false);

  if (esp_now_init() != ESP_OK) {
    Serial.println("[ESP-NOW] 初始化失败！语音控制用不了");
    return;
  }
  esp_now_register_recv_cb(linkOnRecv);

  linkPrefs.begin("link", true);
  if (linkPrefs.getBytesLength("peer") == 6) {
    linkPrefs.getBytes("peer", linkPeer, 6);
    linkPaired = true;
    linkAddPeer(linkPeer);
    printMac("[配对] 已加载语音板 MAC：", linkPeer);
  } else {
    Serial.println("[配对] 还没配对过，长按 BOOT 3 秒进入配对");
  }
  linkPrefs.end();
  Serial.printf("[配对] 本机 MAC：%s\n", WiFi.macAddress().c_str());

  lastLinkMs = millis() - LINK_TIMEOUT_MS;
}

/* 配上了：新 MAC 覆盖旧的。只有这里会改凭证 —— 取消、超时都不动原来的配对 */
static void linkSavePeer(const uint8_t *mac) {
  uint8_t old[6];
  bool hadOld;
  portENTER_CRITICAL(&linkMux);
  hadOld = linkPaired;
  memcpy(old, linkPeer, 6);
  memcpy(linkPeer, mac, 6);
  linkPaired = true;
  portEXIT_CRITICAL(&linkMux);

  if (hadOld && memcmp(old, mac, 6) != 0) esp_now_del_peer(old);
  linkAddPeer(mac);
  linkPrefs.begin("link", false);
  linkPrefs.putBytes("peer", mac, 6);
  linkPrefs.end();
  lastSeq = -1;
  printMac("[配对] 配对成功，语音板 MAC：", mac);
}

/* BOOT 按住满 3 秒触发一次；松手之前不会重复触发 */
static bool bootLongPressed() {
  static uint32_t downSince = 0;
  static bool fired = false;
  if (digitalRead(PIN_BOOT) == LOW) {
    if (downSince == 0) downSince = millis() | 1;
    if (!fired && millis() - downSince >= LINK_PAIR_HOLD_MS) {
      fired = true;
      return true;
    }
  } else {
    downSince = 0;
    fired = false;
  }
  return false;
}

static bool linkConnected() {
  return linkPaired && (millis() - lastLinkMs < LINK_TIMEOUT_MS);
}

static void pollLink() {
  uint32_t now = millis();

  /* 长按 BOOT：进入 / 取消配对；30 秒没配上自动退出 */
  if (bootLongPressed()) {
    if (linkPairing) {
      linkPairing = false;
      Serial.printf("[配对] 取消配对，%s\n", linkPaired ? "继续用原来的配对" : "现在还没有配对");
    } else {
      linkPairingSince = now;
      linkPairing = true;
      Serial.println("[配对] 进入配对模式，30 秒内把语音板也长按 BOOT 3 秒");
    }
  }
  if (linkPairing && now - linkPairingSince >= LINK_PAIR_WINDOW_MS) {
    linkPairing = false;
    Serial.printf("[配对] 配对超时，%s\n", linkPaired ? "继续用原来的配对" : "现在还没有配对");
  }

  /* 配对请求 */
  if (gotPairReq) {
    uint8_t mac[6];
    memcpy(mac, pairReqMac, 6);
    gotPairReq = false;
    if (linkPairing) {
      linkSavePeer(mac);
      linkPairing = false;
    }
    linkSendPairAck(mac);       /* 新配上的发一个；已配上的（它没收到上次的）补一个 */
    lastLinkMs = now;
  }

  /* 语音指令 */
  RxCmd c;
  while (rxQ != nullptr && xQueueReceive(rxQ, &c, 0) == pdTRUE) {
    if ((int)c.seq == lastSeq && now - lastSeqMs < 2000) continue;   /* 重发的同一条 */
    lastSeq   = c.seq;
    lastSeqMs = now;
    char line[LINK_TEXT_MAX + 2];
    line[0] = '$';
    memcpy(line + 1, c.text, c.len);
    line[1 + c.len] = '\0';
    Serial.printf("[语音] 收到: %s\n", line);
    handleVoiceLine(line);
  }

  /* 状态灯：配对中快闪，连上常亮，没连上慢闪 */
  bool connected = linkConnected();
  bool on;
  if (linkPairing)    on = (now / 100) % 2 == 0;
  else if (connected) on = true;
  else                on = (now / 500) % 2 == 0;
  digitalWrite(PIN_LED, on ? HIGH : LOW);

  static bool wasConnected = false;
  if (connected != wasConnected) {
    wasConnected = connected;
    Serial.println(connected ? "[连接] 语音板已连上" : "[连接] 和语音板断开了");
  }
}

/* ==========================================================
 * 九、setup / loop
 * ========================================================== */
void setup() {
  /* OE 先明确拉高（关输出）—— 板上本来有上拉，这里再保险一次；
     等开机状态写进 PCA9685 之后，loop 里才拉低打开 */
  pinMode(PIN_PCA_OE, OUTPUT);
  digitalWrite(PIN_PCA_OE, HIGH);
  pinMode(PIN_LED, OUTPUT);
  digitalWrite(PIN_LED, LOW);
  pinMode(PIN_BOOT, INPUT_PULLUP);

  Serial.begin(115200);                          /* USB CDC 日志 */

  for (uint8_t ch = 0; ch < CH_TOTAL; ch++) lastDuty[ch] = -1;

  loadSettings();                                /* 只恢复亮度 */
  Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL, I2C_SPEED_HZ);
  pcaProbe();                                    /* 接了哪片就初始化哪片 */
  applyBootState();                              /* 主灯日行，辅助灯灭 */
  bleInit();
  linkInit();                                    /* ESP-NOW：收语音板的指令 */

  Serial.println("[init] 控制板启动完毕  上电：主灯日行、辅助灯灭");
}

/* 这一组的白光这会儿该出多少 */
static int spotDuty(uint8_t g, int flashDuty) {
  uint8_t gb = (uint8_t)(1 << g);
  if (flashMask & gb) return flashDuty;
  if (dimMask & gb)   return DUTY_DIM;
  return manualDuty;
}

void loop() {
  /* ---------- 0. 探测板子在不在线（每 2 秒） ---------- */
  probeMs += TICK_MS;
  if (probeMs >= PROBE_MS) {
    pcaProbe();
    probeMs = 0;
  }

  /* ---------- 1. 语音板过来的指令、配对、状态灯 ---------- */
  pollLink();

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
    /* 只在接了的组之间轮流 —— 只接一片板子时，没接的那 4 组不占节拍 */
    uint8_t order[GROUP_COUNT];
    uint8_t n = 0;
    for (uint8_t i = 0; i < GROUP_COUNT; i++) {
      if (groupPresent(partyOrder[i])) order[n++] = partyOrder[i];
    }
    partyMs += TICK_MS;
    if (n > 0) {
      uint32_t cycle = (uint32_t)n * PARTY_STEPS_PER_GROUP;
      uint32_t step  = (partyMs / PARTY_STEP_MS) % cycle;
      partyMs %= cycle * PARTY_STEP_MS;
      /* 每组内部是 亮-灭-亮-灭：偶数步亮 */
      if ((step % PARTY_STEPS_PER_GROUP) % 2 == 0) {
        partyGroup = order[step / PARTY_STEPS_PER_GROUP];
      }
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

  /* 第一次把开机状态写进 PCA9685 之后，才打开输出（OE 拉低） */
  if (!outputsEnabled) {
    outputsEnabled = true;
    digitalWrite(PIN_PCA_OE, LOW);
    Serial.println("[PCA] 输出已打开（OE 拉低）");
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
    Serial.printf("PCA:%s%s Voice:%s Mask:0x%08lX Flash:0x%02X Dim:0x%02X Party:%s Duty:%u%% BLE:%s Notify:%lu |",
                  pcaOk[0] ? "40" : "--", pcaOk[1] ? "41" : "--",
                  linkConnected() ? "ON" : (linkPaired ? "--" : "NP"),
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
