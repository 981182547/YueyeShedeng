#include "asr.h"
extern "C"{ void * __dso_handle = 0 ;}
#include "setup.h"
#include "HardwareSerial.h"
#include "myLib/asr_event.h"

uint32_t snid;
void ASR_CODE();

//{speak:小蝶-清新女声,vol:10,speed:10,platform:haohaodada}
//{playid:10001,voice:}
//{playid:10002,voice:}

/* ============================================================
 * 越野射灯 2.0 —— 语音命令，串口指令协议（115200）
 *
 * 不用唤醒词：hardware_init 里 set_wakeup_forever() 让模块一直处于唤醒状态，
 * 直接说命令就行。ASR_CODE 里【不要】再调 set_state_enter_wakeup() ——
 * 它会把唤醒时间改回几秒，时间一到模块就休眠，没有唤醒词就再也叫不醒了。
 *
 * 每条指令一行：  $<灯组>:<动作>\r\n      例：$APD:DRL
 *
 * 接收端必须【整行精确比对】，不能用 strstr 找子串 ——
 * 否则 $ALL:PARTY 会误匹配到 $ALL:PARTY_OFF。
 * 推荐做法：按冒号拆成 灯组 + 动作 两段，各查一张表。
 *
 * 8 组灯，编号和车图上标的一致：
 *
 *   编号 代码  灯组          分类     说法
 *   1    BMP   前杠灯        主灯     前杠
 *   2    APD   A柱直射灯     主灯     A柱直射
 *   3    APS   A柱侧位灯     主灯     A柱侧位
 *   4    ROF   顶灯          主灯     车顶
 *   5    BMI   前杠内侧灯    辅助灯   前杠内侧
 *   6    BMO   前杠外侧灯    辅助灯   前杠外侧
 *   7    RGT   右侧灯        辅助灯   右侧
 *   8    LFT   左侧灯        辅助灯   左侧
 *
 *   MAIN = 主灯 1~4 组    AUX = 辅助灯 5~8 组    ALL = 全车
 *
 * 每组 5 条说法（不带「灯」字）：
 *   打开X -> ON   打开X日行 -> DRL   打开X氛围 -> AMB   打开X爆闪 -> FLASH   关闭X -> OFF
 *
 * 动作：
 *   ON        白光
 *   DRL 日行    AMB 氛围    FLASH 爆闪    OFF 关闭
 *   DIM       微亮 = 日行 + 白光 10%（只有 MAIN 有）
 *   PARTY     娱乐模式，8 组轮流爆闪（只有 ALL 有）
 *   PARTY_OFF 退出娱乐模式
 *
 * ID 编码：组号 x10 + 动作号
 *   单灯    N1 DRL   N2 AMB   N3 FLASH   N4 OFF   N5 ON   （N = 1~8，就是灯的编号）
 *   主灯    101 DRL  102 AMB  103 FLASH  104 OFF  105 ON  106 DIM
 *   辅助灯  111 DRL  112 AMB  113 FLASH  114 OFF  115 ON
 *   全车    121 PARTY  122 PARTY_OFF  123 OFF
 *
 * 识别词里不能有英文字母，「A柱」写成同音的「诶柱」；
 * 回复语照常写「A柱」，播报读起来更自然。
 * ============================================================ */

/* 发一条指令。格式集中在这里，以后要改协议只改这一处 */
void sendCmd(const char *cmd) {
  Serial.print("$");
  Serial.print(cmd);
  Serial.print("\r\n");
}

/*描述该功能...
*/
void ASR_CODE(){
  //本函数是语音识别成功钩子程序
  //运行时间越短越好，复杂控制启动新线程运行
  //这里不设唤醒时间：模块是永久唤醒的，见文件头说明

  switch (snid) {
    /* 1 前杠灯（主灯） */
    case 11:  sendCmd("BMP:DRL");       break;
    case 12:  sendCmd("BMP:AMB");       break;
    case 13:  sendCmd("BMP:FLASH");     break;
    case 14:  sendCmd("BMP:OFF");       break;
    case 15:  sendCmd("BMP:ON");        break;

    /* 2 A柱直射灯（主灯） */
    case 21:  sendCmd("APD:DRL");       break;
    case 22:  sendCmd("APD:AMB");       break;
    case 23:  sendCmd("APD:FLASH");     break;
    case 24:  sendCmd("APD:OFF");       break;
    case 25:  sendCmd("APD:ON");        break;

    /* 3 A柱侧位灯（主灯） */
    case 31:  sendCmd("APS:DRL");       break;
    case 32:  sendCmd("APS:AMB");       break;
    case 33:  sendCmd("APS:FLASH");     break;
    case 34:  sendCmd("APS:OFF");       break;
    case 35:  sendCmd("APS:ON");        break;

    /* 4 顶灯（主灯） */
    case 41:  sendCmd("ROF:DRL");       break;
    case 42:  sendCmd("ROF:AMB");       break;
    case 43:  sendCmd("ROF:FLASH");     break;
    case 44:  sendCmd("ROF:OFF");       break;
    case 45:  sendCmd("ROF:ON");        break;

    /* 5 前杠内侧灯（辅助灯） */
    case 51:  sendCmd("BMI:DRL");       break;
    case 52:  sendCmd("BMI:AMB");       break;
    case 53:  sendCmd("BMI:FLASH");     break;
    case 54:  sendCmd("BMI:OFF");       break;
    case 55:  sendCmd("BMI:ON");        break;

    /* 6 前杠外侧灯（辅助灯） */
    case 61:  sendCmd("BMO:DRL");       break;
    case 62:  sendCmd("BMO:AMB");       break;
    case 63:  sendCmd("BMO:FLASH");     break;
    case 64:  sendCmd("BMO:OFF");       break;
    case 65:  sendCmd("BMO:ON");        break;

    /* 7 右侧灯（辅助灯） */
    case 71:  sendCmd("RGT:DRL");       break;
    case 72:  sendCmd("RGT:AMB");       break;
    case 73:  sendCmd("RGT:FLASH");     break;
    case 74:  sendCmd("RGT:OFF");       break;
    case 75:  sendCmd("RGT:ON");        break;

    /* 8 左侧灯（辅助灯） */
    case 81:  sendCmd("LFT:DRL");       break;
    case 82:  sendCmd("LFT:AMB");       break;
    case 83:  sendCmd("LFT:FLASH");     break;
    case 84:  sendCmd("LFT:OFF");       break;
    case 85:  sendCmd("LFT:ON");        break;

    /* 主灯 1~4 组一起 */
    case 101: sendCmd("MAIN:DRL");      break;
    case 102: sendCmd("MAIN:AMB");      break;
    case 103: sendCmd("MAIN:FLASH");    break;
    case 104: sendCmd("MAIN:OFF");      break;
    case 105: sendCmd("MAIN:ON");       break;
    case 106: sendCmd("MAIN:DIM");      break;

    /* 辅助灯 5~8 组一起 */
    case 111: sendCmd("AUX:DRL");       break;
    case 112: sendCmd("AUX:AMB");       break;
    case 113: sendCmd("AUX:FLASH");     break;
    case 114: sendCmd("AUX:OFF");       break;
    case 115: sendCmd("AUX:ON");        break;

    /* 全车 */
    case 121: sendCmd("ALL:PARTY");     break;
    case 122: sendCmd("ALL:PARTY_OFF"); break;
    case 123: sendCmd("ALL:OFF");       break;

    default: break;
  }
}

void hardware_init(){
  //需要操作系统启动后初始化的内容
  //音量范围1-7
  vol_set(7);
  set_wakeup_forever();   // 永久唤醒：不用唤醒词，直接说命令
  vTaskDelete(NULL);
}

void setup()
{
  setPinFun(13,SECOND_FUNCTION);
  setPinFun(14,SECOND_FUNCTION);
  Serial.begin(115200);
  //需要操作系统启动前初始化的内容
  //播报音下拉菜单可以选择，合成音量是指TTS生成文件的音量
  //欢迎词指开机提示音，可以为空
  //退出语音是指休眠时提示音，可以为空
  //不用唤醒词：模块永久唤醒（见 hardware_init），直接说命令。回复语可以空。ID范围为0-9999
  //{ID:11,keyword:"命令词",ASR:"打开前杠日行",ASRTO:"好的，马上打开前杠日行"}
  //{ID:12,keyword:"命令词",ASR:"打开前杠氛围",ASRTO:"好的，马上打开前杠氛围"}
  //{ID:13,keyword:"命令词",ASR:"打开前杠爆闪",ASRTO:"好的，马上打开前杠爆闪"}
  //{ID:14,keyword:"命令词",ASR:"关闭前杠",ASRTO:"好的，马上关闭前杠"}
  //{ID:15,keyword:"命令词",ASR:"打开前杠",ASRTO:"好的，马上打开前杠"}
  //{ID:21,keyword:"命令词",ASR:"打开诶柱直射日行",ASRTO:"好的，马上打开A柱直射日行"}
  //{ID:22,keyword:"命令词",ASR:"打开诶柱直射氛围",ASRTO:"好的，马上打开A柱直射氛围"}
  //{ID:23,keyword:"命令词",ASR:"打开诶柱直射爆闪",ASRTO:"好的，马上打开A柱直射爆闪"}
  //{ID:24,keyword:"命令词",ASR:"关闭诶柱直射",ASRTO:"好的，马上关闭A柱直射"}
  //{ID:25,keyword:"命令词",ASR:"打开诶柱直射",ASRTO:"好的，马上打开A柱直射"}
  //{ID:31,keyword:"命令词",ASR:"打开诶柱侧位日行",ASRTO:"好的，马上打开A柱侧位日行"}
  //{ID:32,keyword:"命令词",ASR:"打开诶柱侧位氛围",ASRTO:"好的，马上打开A柱侧位氛围"}
  //{ID:33,keyword:"命令词",ASR:"打开诶柱侧位爆闪",ASRTO:"好的，马上打开A柱侧位爆闪"}
  //{ID:34,keyword:"命令词",ASR:"关闭诶柱侧位",ASRTO:"好的，马上关闭A柱侧位"}
  //{ID:35,keyword:"命令词",ASR:"打开诶柱侧位",ASRTO:"好的，马上打开A柱侧位"}
  //{ID:41,keyword:"命令词",ASR:"打开车顶日行",ASRTO:"好的，马上打开车顶日行"}
  //{ID:42,keyword:"命令词",ASR:"打开车顶氛围",ASRTO:"好的，马上打开车顶氛围"}
  //{ID:43,keyword:"命令词",ASR:"打开车顶爆闪",ASRTO:"好的，马上打开车顶爆闪"}
  //{ID:44,keyword:"命令词",ASR:"关闭车顶",ASRTO:"好的，马上关闭车顶"}
  //{ID:45,keyword:"命令词",ASR:"打开车顶",ASRTO:"好的，马上打开车顶"}
  //{ID:51,keyword:"命令词",ASR:"打开前杠内侧日行",ASRTO:"好的，马上打开前杠内侧日行"}
  //{ID:52,keyword:"命令词",ASR:"打开前杠内侧氛围",ASRTO:"好的，马上打开前杠内侧氛围"}
  //{ID:53,keyword:"命令词",ASR:"打开前杠内侧爆闪",ASRTO:"好的，马上打开前杠内侧爆闪"}
  //{ID:54,keyword:"命令词",ASR:"关闭前杠内侧",ASRTO:"好的，马上关闭前杠内侧"}
  //{ID:55,keyword:"命令词",ASR:"打开前杠内侧",ASRTO:"好的，马上打开前杠内侧"}
  //{ID:61,keyword:"命令词",ASR:"打开前杠外侧日行",ASRTO:"好的，马上打开前杠外侧日行"}
  //{ID:62,keyword:"命令词",ASR:"打开前杠外侧氛围",ASRTO:"好的，马上打开前杠外侧氛围"}
  //{ID:63,keyword:"命令词",ASR:"打开前杠外侧爆闪",ASRTO:"好的，马上打开前杠外侧爆闪"}
  //{ID:64,keyword:"命令词",ASR:"关闭前杠外侧",ASRTO:"好的，马上关闭前杠外侧"}
  //{ID:65,keyword:"命令词",ASR:"打开前杠外侧",ASRTO:"好的，马上打开前杠外侧"}
  //{ID:71,keyword:"命令词",ASR:"打开右侧日行",ASRTO:"好的，马上打开右侧日行"}
  //{ID:72,keyword:"命令词",ASR:"打开右侧氛围",ASRTO:"好的，马上打开右侧氛围"}
  //{ID:73,keyword:"命令词",ASR:"打开右侧爆闪",ASRTO:"好的，马上打开右侧爆闪"}
  //{ID:74,keyword:"命令词",ASR:"关闭右侧",ASRTO:"好的，马上关闭右侧"}
  //{ID:75,keyword:"命令词",ASR:"打开右侧",ASRTO:"好的，马上打开右侧"}
  //{ID:81,keyword:"命令词",ASR:"打开左侧日行",ASRTO:"好的，马上打开左侧日行"}
  //{ID:82,keyword:"命令词",ASR:"打开左侧氛围",ASRTO:"好的，马上打开左侧氛围"}
  //{ID:83,keyword:"命令词",ASR:"打开左侧爆闪",ASRTO:"好的，马上打开左侧爆闪"}
  //{ID:84,keyword:"命令词",ASR:"关闭左侧",ASRTO:"好的，马上关闭左侧"}
  //{ID:85,keyword:"命令词",ASR:"打开左侧",ASRTO:"好的，马上打开左侧"}
  //{ID:101,keyword:"命令词",ASR:"打开主灯日行",ASRTO:"好的，马上打开主灯日行"}
  //{ID:102,keyword:"命令词",ASR:"打开主灯氛围",ASRTO:"好的，马上打开主灯氛围"}
  //{ID:103,keyword:"命令词",ASR:"打开主灯爆闪",ASRTO:"好的，马上打开主灯爆闪"}
  //{ID:104,keyword:"命令词",ASR:"关闭主灯",ASRTO:"好的，马上关闭主灯"}
  //{ID:105,keyword:"命令词",ASR:"打开主灯",ASRTO:"好的，马上打开主灯"}
  //{ID:106,keyword:"命令词",ASR:"打开主灯微亮",ASRTO:"好的，马上打开主灯微亮"}
  //{ID:111,keyword:"命令词",ASR:"打开辅助日行",ASRTO:"好的，马上打开辅助日行"}
  //{ID:112,keyword:"命令词",ASR:"打开辅助氛围",ASRTO:"好的，马上打开辅助氛围"}
  //{ID:113,keyword:"命令词",ASR:"打开辅助爆闪",ASRTO:"好的，马上打开辅助爆闪"}
  //{ID:114,keyword:"命令词",ASR:"关闭辅助灯",ASRTO:"好的，马上关闭辅助灯"}
  //{ID:115,keyword:"命令词",ASR:"打开辅助灯",ASRTO:"好的，马上打开辅助灯"}
  //{ID:121,keyword:"命令词",ASR:"打开娱乐模式",ASRTO:"好的，马上打开娱乐模式"}
  //{ID:122,keyword:"命令词",ASR:"关闭娱乐模式",ASRTO:"好的，马上关闭娱乐模式"}
  //{ID:123,keyword:"命令词",ASR:"关闭全车灯光",ASRTO:"好的，马上关闭全车灯光"}
  setPinFun(4,FIRST_FUNCTION);
  pinMode(4,output);
  digitalWrite(4,0);   // 上电先拉低，保证开机时灯是灭的
}
