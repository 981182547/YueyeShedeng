/*
 * 智能语音射灯控制器 —— ESP32-C3 / Arduino IDE 版（无 AI 视觉）
 * CI1302 语音指令 + 雨滴 + 光敏 + PCA9685 16 路灯光
 *
 * 硬件连接：
 *   IO4  -> PCA9685 SDA        IO5  -> PCA9685 SCL
 *   IO7  -> 雨滴 DO (低=下雨)   IO8  -> 光敏 DO (低=白天, 高=黑夜)
 *   IO21 -> CI1302 RX          IO20 <- CI1302 TX
 *   PCA9685: CH0~CH7 = 黄光, CH8~CH15 = 白光
 *
 * Arduino IDE 设置：
 *   开发板   : ESP32C3 Dev Module
 *   USB CDC On Boot : Enabled      (日志走 Type-C 的 IO18/IO19 原生 USB)
 *   不需要装任何第三方库，PCA9685 直接用 Wire 写寄存器
 */

#include <Wire.h>
#include <math.h>

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

#define CH_YELLOW_START  0       /* 前 8 路：黄光 */
#define CH_YELLOW_CNT    8
#define CH_WHITE_START   8       /* 后 8 路：白光 */
#define CH_WHITE_CNT     8

#define TICK_MS          10      /* 主循环周期 */
#define SMOOTH_FACTOR    0.06f   /* 亮度渐变系数，越小越柔和 */
#define DEBOUNCE_TICKS   8       /* 传感器消抖：连续 8 次(80ms) */

#define DUTY_DAY         20.0f   /* 白天日行灯亮度 */
#define DUTY_NIGHT       100.0f  /* 夜间全亮 */
#define DUTY_DRL         10.0f   /* 语音日行灯模式 */

HardwareSerial ASR(1);           /* 用 UART1，避开 USB CDC 日志 */

/* ==========================================================
 * 二、PCA9685 驱动（裸寄存器）
 * ========================================================== */
#define PCA_MODE1        0x00
#define PCA_MODE2        0x01
#define PCA_LED0_ON_L    0x06
#define PCA_ALL_LED_ON_L 0xFA
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

/* 设置一组通道占空比 0~100%，相位错开降低电源尖峰 */
static void pcaSetGroup(uint8_t start, uint8_t count, int duty) {
  if (duty < 0)   duty = 0;
  if (duty > 100) duty = 100;
  for (uint8_t i = 0; i < count; i++) {
    uint8_t ch = start + i;
    if (duty == 0) {
      pcaWriteLed(ch, 0, 0x1000);                /* full OFF */
    } else if (duty == 100) {
      pcaWriteLed(ch, 0x1000, 0);                /* full ON  */
    } else {
      uint16_t on  = (uint16_t)(ch * 256) & 0x0FFF;
      uint16_t len = (uint16_t)(duty * 4096 / 100);
      uint16_t off = (on + len) & 0x0FFF;
      pcaWriteLed(ch, on, off);
    }
  }
}

/* 16 路一起设成同一亮度：用 ALL_LED 寄存器，一次 I2C 写完，黄白严格同步 */
static void pcaSetAll(int duty) {
  if (duty < 0)   duty = 0;
  if (duty > 100) duty = 100;
  Wire.beginTransmission(PCA9685_ADDR);
  Wire.write(PCA_ALL_LED_ON_L);
  if (duty == 0) {                                   /* full OFF */
    Wire.write(0x00); Wire.write(0x00);
    Wire.write(0x00); Wire.write(0x10);
  } else if (duty == 100) {                          /* full ON  */
    Wire.write(0x00); Wire.write(0x10);
    Wire.write(0x00); Wire.write(0x00);
  } else {
    uint16_t off = (uint16_t)(duty * 4096 / 100);
    Wire.write(0x00);          Wire.write(0x00);
    Wire.write(off & 0xFF);    Wire.write(off >> 8);
  }
  Wire.endTransmission();
}

/* 只在数值变化时才刷 I2C */
static int lastYellow = -1, lastWhite = -1;
static void lightsOutput(int yellow, int white) {
  if (yellow != lastYellow) { pcaSetGroup(CH_YELLOW_START, CH_YELLOW_CNT, yellow); lastYellow = yellow; }
  if (white  != lastWhite ) { pcaSetGroup(CH_WHITE_START,  CH_WHITE_CNT,  white ); lastWhite  = white;  }
}

static void lightsOutputAll(int duty) {
  if (duty != lastYellow || duty != lastWhite) {
    pcaSetAll(duty);
    lastYellow = duty;
    lastWhite  = duty;
  }
}

/* ==========================================================
 * 三、状态机定义
 * ========================================================== */
enum SysMode   { MODE_AUTO = 0, MODE_MANUAL, MODE_FLASH };
enum ActiveCh  { CH_WHITE_ACTIVE = 0, CH_YELLOW_ACTIVE };

/* 爆闪节奏表：{持续ms, 亮度%}，黄白 16 路一起闪（三连闪 + 间隔）
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

static SysMode  sysMode     = MODE_MANUAL;   /* 开机默认关灯，等语音指令再亮 */
static ActiveCh activeLight = CH_WHITE_ACTIVE;
static float    manualDuty  = 0.0f;
static float    curYellow = 0.0f, curWhite = 0.0f;

/* 传感器状态：开机默认 天亮(0) / 没雨(1) */
static int lightStable = 0, lightCnt = 0;
static int rainStable  = 1, rainCnt  = 0;
static int lastRain    = 1;

static uint32_t flashIdx = 0, flashMs = 0, logMs = 0;
static const char *reason = "Boot";

/* 消抖读取 */
static int debounceRead(int pin, int &stable, int &cnt) {
  int v = digitalRead(pin);
  if (v == stable)                 cnt = 0;
  else if (++cnt >= DEBOUNCE_TICKS) { stable = v; cnt = 0; }
  return stable;
}

/* 读一帧语音指令，转大写并去掉空白，无数据返回 false */
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

/* ==========================================================
 * 四、setup / loop
 * ========================================================== */
void setup() {
  Serial.begin(115200);                          /* USB CDC 日志 */
  ASR.begin(ASR_BAUD, SERIAL_8N1, PIN_ASR_RX, PIN_ASR_TX);

  pinMode(PIN_RAIN,  INPUT_PULLUP);
  pinMode(PIN_LIGHT, INPUT_PULLUP);

  pca9685Init(PCA9685_FREQ_HZ);
  Serial.println("[init] 系统启动完毕  FW=BL-FLASH-v3");
}

void loop() {
  char cmd[128];

  /* ---------- 0. 传感器轮询 ---------- */
  int curLight = debounceRead(PIN_LIGHT, lightStable, lightCnt);  /* 0=白天 1=黑夜 */
  int curRain  = debounceRead(PIN_RAIN,  rainStable,  rainCnt);   /* 0=下雨 1=干燥 */

  /* 雨滴边沿：只切通道，不抢模式控制权 */
  if (curRain == 0 && lastRain == 1) {
    activeLight = CH_YELLOW_ACTIVE;
    Serial.println(">> [Sensor] 检测到下雨，自动切黄光穿透雨雾");
  } else if (curRain == 1 && lastRain == 0) {
    activeLight = CH_WHITE_ACTIVE;
    Serial.println(">> [Sensor] 雨停，自动切回白光");
  }
  lastRain = curRain;

  /* ---------- 1. 语音指令 ---------- */
  if (asrReadCmd(cmd, sizeof(cmd))) {
    Serial.printf("[Voice] 收到指令: %s\n", cmd);

    if (strstr(cmd, "WHT")) {                                  /* 白光 */
      activeLight = CH_WHITE_ACTIVE;
      if (sysMode == MODE_FLASH) sysMode = MODE_AUTO;
      Serial.println(">> 通道切换: 白光");
    } else if (strstr(cmd, "YEL") || strstr(cmd, "RED")) {     /* 黄光 */
      activeLight = CH_YELLOW_ACTIVE;
      if (sysMode == MODE_FLASH) sysMode = MODE_AUTO;
      Serial.println(">> 通道切换: 黄光");
    } else if (strstr(cmd, "BLBL") || strstr(cmd, "BL")) {     /* 爆闪，词条整条是 BLBL */
      if (sysMode != MODE_FLASH) {      /* 重复收到同一条指令时别重置节奏，否则会卡在第一步变常亮 */
        sysMode  = MODE_FLASH;
        flashIdx = 0;
        flashMs  = 0;
      }
      Serial.println(">> 模式切换: 爆闪");
    } else if (strstr(cmd, "AUTO")) {
      sysMode = MODE_AUTO;
      Serial.println(">> 模式切换: 自动（传感器接管）");
    } else if (strstr(cmd, "OFF")) {
      sysMode = MODE_MANUAL; manualDuty = 0.0f;
      Serial.println(">> 模式切换: 关灯");
    } else if (strstr(cmd, "ON")) {
      sysMode = MODE_MANUAL; manualDuty = 100.0f;
      Serial.println(">> 模式切换: 常亮 100%");
    } else if (strstr(cmd, "DRL")) {
      sysMode = MODE_MANUAL; manualDuty = DUTY_DRL;
      Serial.println(">> 模式切换: 日行灯");
    } else {
      Serial.print(">> [Voice] 未匹配任何指令, HEX:");
      for (size_t i = 0; cmd[i]; i++) Serial.printf(" %02X", (uint8_t)cmd[i]);
      Serial.println();
    }
  }

  /* ---------- 2. 计算目标亮度 ---------- */
  if (sysMode == MODE_FLASH) {
    /* 爆闪：只闪当前激活通道，走节奏表，跳过渐变直接硬切 */
    flashMs += TICK_MS;
    if (flashMs >= flashPattern[flashIdx].ms) {
      flashMs = 0;
      flashIdx = (flashIdx + 1) % FLASH_STEPS;
    }
    float flashDuty = flashPattern[flashIdx].duty;
    if (activeLight == CH_WHITE_ACTIVE) {
      curWhite  = flashDuty;                       /* 白光激活才爆闪 */
      curYellow = 0.0f;
    } else {
      curYellow = flashDuty;                       /* 黄光激活才爆闪 */
      curWhite  = 0.0f;
    }
    reason = "Flash Mode";
  } else {
    float baseDuty;
    if (sysMode == MODE_AUTO) {
      if (curLight == 0) { baseDuty = DUTY_DAY;   reason = "Daytime (Light Sensor)"; }
      else               { baseDuty = DUTY_NIGHT; reason = "Night (Light Sensor)";   }
    } else {
      baseDuty = manualDuty;  reason = "Voice Override";
    }

    /* 路由：亮度只给当前通道，另一路强制为 0 */
    float targetYellow = 0.0f, targetWhite = 0.0f;
    if (activeLight == CH_WHITE_ACTIVE) targetWhite  = baseDuty;
    else                                targetYellow = baseDuty;

    /* 平滑渐变 */
    curYellow += (targetYellow - curYellow) * SMOOTH_FACTOR;
    curWhite  += (targetWhite  - curWhite ) * SMOOTH_FACTOR;
    if (fabsf(targetYellow - curYellow) < 0.5f) curYellow = targetYellow;
    if (fabsf(targetWhite  - curWhite ) < 0.5f) curWhite  = targetWhite;
  }

  /* ---------- 3. 输出 ---------- */
  lightsOutput((int)(curYellow + 0.5f), (int)(curWhite + 0.5f));

  /* ---------- 4. 状态打印（每 1s） ---------- */
  logMs += TICK_MS;
  if (logMs >= 1000) {
    logMs = 0;
    const char *modeStr = (sysMode == MODE_AUTO) ? "AUTO" :
                          (sysMode == MODE_MANUAL) ? "MANUAL" : "FLASH";
    Serial.printf("Mode:[%s] Ch:[%s] Light:%s Rain:%s | %s | Y:%d%% W:%d%%\n",
                  modeStr,
                  (activeLight == CH_WHITE_ACTIVE) ? "WHITE" : "YELLOW",
                  curLight ? "Night" : "Day",
                  curRain  ? "Dry"   : "Rain",
                  reason,
                  (int)curYellow, (int)curWhite);
  }

  delay(TICK_MS);
}