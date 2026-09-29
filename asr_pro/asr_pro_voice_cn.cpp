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
 * 越野射灯 2.0 —— 语音命令【中文 · 数字编号版】，串口指令协议（115200）
 *
 * 说法用车图上的编号 1~8，不说灯名：
 *   打开N号灯 -> ON（白光）   打开N号日行 -> DRL   打开N号氛围 -> AMB
 *   打开N号爆闪 -> FLASH      关闭N号灯 -> OFF
 * 识别词只能是汉字，所以编号写成「一号」「二号」……，不能写 1、2。
 *
 * 中文版和英文版的 ID、串口指令完全一样，ESP32 固件不用区分装的是哪一版。
 *
 * 不用唤醒词：hardware_init 里 set_wakeup_forever() 让模块一直处于唤醒状态，
 * 直接说命令就行。ASR_CODE 里【不要】再调 set_state_enter_wakeup() ——
 * 它会把唤醒时间改回几秒，时间一到模块就休眠，没有唤醒词就再也叫不醒了。
 *
 * 每条指令一行：  $<灯组>:<动作>\r\n      例：$APD:DRL
 * 接收端按冒号拆成 灯组 + 动作 两段，各自【整串比对】，不能用 strstr。
 *
 *   编号 代码  灯组          分类
 *   1    BMP   前杠灯      主灯
 *   2    APD   A柱直射灯   主灯
 *   3    APS   A柱侧位灯   主灯
 *   4    ROF   顶灯        主灯
 *   5    BMI   前杠内侧灯  辅助灯
 *   6    BMO   前杠外侧灯  辅助灯
 *   7    RGT   右侧灯      辅助灯
 *   8    LFT   左侧灯      辅助灯
 *
 *   MAIN = 主灯 1~4 号    AUX = 辅助灯 5~8 号    ALL = 全车
 *
 * ID 编码：编号 x10 + 动作号
 *   单灯    N1 DRL   N2 AMB   N3 FLASH   N4 OFF   N5 ON   （N = 1~8）
 *   主灯    101 DRL  102 AMB  103 FLASH  104 OFF  105 ON  106 DIM
 *   辅助灯  111 DRL  112 AMB  113 FLASH  114 OFF  115 ON
 *   全车    121 PARTY  122 PARTY_OFF  123 OFF
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
    /* 1 号：前杠灯（主灯） */
    case 11:  sendCmd("BMP:DRL");       break;
    case 12:  sendCmd("BMP:AMB");       break;
    case 13:  sendCmd("BMP:FLASH");     break;
    case 14:  sendCmd("BMP:OFF");       break;
    case 15:  sendCmd("BMP:ON");        break;

    /* 2 号：A柱直射灯（主灯） */
    case 21:  sendCmd("APD:DRL");       break;
    case 22:  sendCmd("APD:AMB");       break;
    case 23:  sendCmd("APD:FLASH");     break;
    case 24:  sendCmd("APD:OFF");       break;
    case 25:  sendCmd("APD:ON");        break;

    /* 3 号：A柱侧位灯（主灯） */
    case 31:  sendCmd("APS:DRL");       break;
    case 32:  sendCmd("APS:AMB");       break;
    case 33:  sendCmd("APS:FLASH");     break;
    case 34:  sendCmd("APS:OFF");       break;
    case 35:  sendCmd("APS:ON");        break;

    /* 4 号：顶灯（主灯） */
    case 41:  sendCmd("ROF:DRL");       break;
    case 42:  sendCmd("ROF:AMB");       break;
    case 43:  sendCmd("ROF:FLASH");     break;
    case 44:  sendCmd("ROF:OFF");       break;
    case 45:  sendCmd("ROF:ON");        break;

    /* 5 号：前杠内侧灯（辅助灯） */
    case 51:  sendCmd("BMI:DRL");       break;
    case 52:  sendCmd("BMI:AMB");       break;
    case 53:  sendCmd("BMI:FLASH");     break;
    case 54:  sendCmd("BMI:OFF");       break;
    case 55:  sendCmd("BMI:ON");        break;

    /* 6 号：前杠外侧灯（辅助灯） */
    case 61:  sendCmd("BMO:DRL");       break;
    case 62:  sendCmd("BMO:AMB");       break;
    case 63:  sendCmd("BMO:FLASH");     break;
    case 64:  sendCmd("BMO:OFF");       break;
    case 65:  sendCmd("BMO:ON");        break;

    /* 7 号：右侧灯（辅助灯） */
    case 71:  sendCmd("RGT:DRL");       break;
    case 72:  sendCmd("RGT:AMB");       break;
    case 73:  sendCmd("RGT:FLASH");     break;
    case 74:  sendCmd("RGT:OFF");       break;
    case 75:  sendCmd("RGT:ON");        break;

    /* 8 号：左侧灯（辅助灯） */
    case 81:  sendCmd("LFT:DRL");       break;
    case 82:  sendCmd("LFT:AMB");       break;
    case 83:  sendCmd("LFT:FLASH");     break;
    case 84:  sendCmd("LFT:OFF");       break;
    case 85:  sendCmd("LFT:ON");        break;

    /* 主灯 1~4 号一起 */
    case 101: sendCmd("MAIN:DRL");      break;
    case 102: sendCmd("MAIN:AMB");      break;
    case 103: sendCmd("MAIN:FLASH");    break;
    case 104: sendCmd("MAIN:OFF");      break;
    case 105: sendCmd("MAIN:ON");       break;
    case 106: sendCmd("MAIN:DIM");      break;

    /* 辅助灯 5~8 号一起 */
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
  //{ID:11,keyword:"命令词",ASR:"打开一号日行",ASRTO:"好的，马上打开一号日行"}
  //{ID:12,keyword:"命令词",ASR:"打开一号氛围",ASRTO:"好的，马上打开一号氛围"}
  //{ID:13,keyword:"命令词",ASR:"打开一号爆闪",ASRTO:"好的，马上打开一号爆闪"}
  //{ID:14,keyword:"命令词",ASR:"关闭一号灯",ASRTO:"好的，马上关闭一号灯"}
  //{ID:15,keyword:"命令词",ASR:"打开一号灯",ASRTO:"好的，马上打开一号灯"}
  //{ID:21,keyword:"命令词",ASR:"打开二号日行",ASRTO:"好的，马上打开二号日行"}
  //{ID:22,keyword:"命令词",ASR:"打开二号氛围",ASRTO:"好的，马上打开二号氛围"}
  //{ID:23,keyword:"命令词",ASR:"打开二号爆闪",ASRTO:"好的，马上打开二号爆闪"}
  //{ID:24,keyword:"命令词",ASR:"关闭二号灯",ASRTO:"好的，马上关闭二号灯"}
  //{ID:25,keyword:"命令词",ASR:"打开二号灯",ASRTO:"好的，马上打开二号灯"}
  //{ID:31,keyword:"命令词",ASR:"打开三号日行",ASRTO:"好的，马上打开三号日行"}
  //{ID:32,keyword:"命令词",ASR:"打开三号氛围",ASRTO:"好的，马上打开三号氛围"}
  //{ID:33,keyword:"命令词",ASR:"打开三号爆闪",ASRTO:"好的，马上打开三号爆闪"}
  //{ID:34,keyword:"命令词",ASR:"关闭三号灯",ASRTO:"好的，马上关闭三号灯"}
  //{ID:35,keyword:"命令词",ASR:"打开三号灯",ASRTO:"好的，马上打开三号灯"}
  //{ID:41,keyword:"命令词",ASR:"打开四号日行",ASRTO:"好的，马上打开四号日行"}
  //{ID:42,keyword:"命令词",ASR:"打开四号氛围",ASRTO:"好的，马上打开四号氛围"}
  //{ID:43,keyword:"命令词",ASR:"打开四号爆闪",ASRTO:"好的，马上打开四号爆闪"}
  //{ID:44,keyword:"命令词",ASR:"关闭四号灯",ASRTO:"好的，马上关闭四号灯"}
  //{ID:45,keyword:"命令词",ASR:"打开四号灯",ASRTO:"好的，马上打开四号灯"}
  //{ID:51,keyword:"命令词",ASR:"打开五号日行",ASRTO:"好的，马上打开五号日行"}
  //{ID:52,keyword:"命令词",ASR:"打开五号氛围",ASRTO:"好的，马上打开五号氛围"}
  //{ID:53,keyword:"命令词",ASR:"打开五号爆闪",ASRTO:"好的，马上打开五号爆闪"}
  //{ID:54,keyword:"命令词",ASR:"关闭五号灯",ASRTO:"好的，马上关闭五号灯"}
  //{ID:55,keyword:"命令词",ASR:"打开五号灯",ASRTO:"好的，马上打开五号灯"}
  //{ID:61,keyword:"命令词",ASR:"打开六号日行",ASRTO:"好的，马上打开六号日行"}
  //{ID:62,keyword:"命令词",ASR:"打开六号氛围",ASRTO:"好的，马上打开六号氛围"}
  //{ID:63,keyword:"命令词",ASR:"打开六号爆闪",ASRTO:"好的，马上打开六号爆闪"}
  //{ID:64,keyword:"命令词",ASR:"关闭六号灯",ASRTO:"好的，马上关闭六号灯"}
  //{ID:65,keyword:"命令词",ASR:"打开六号灯",ASRTO:"好的，马上打开六号灯"}
  //{ID:71,keyword:"命令词",ASR:"打开七号日行",ASRTO:"好的，马上打开七号日行"}
  //{ID:72,keyword:"命令词",ASR:"打开七号氛围",ASRTO:"好的，马上打开七号氛围"}
  //{ID:73,keyword:"命令词",ASR:"打开七号爆闪",ASRTO:"好的，马上打开七号爆闪"}
  //{ID:74,keyword:"命令词",ASR:"关闭七号灯",ASRTO:"好的，马上关闭七号灯"}
  //{ID:75,keyword:"命令词",ASR:"打开七号灯",ASRTO:"好的，马上打开七号灯"}
  //{ID:81,keyword:"命令词",ASR:"打开八号日行",ASRTO:"好的，马上打开八号日行"}
  //{ID:82,keyword:"命令词",ASR:"打开八号氛围",ASRTO:"好的，马上打开八号氛围"}
  //{ID:83,keyword:"命令词",ASR:"打开八号爆闪",ASRTO:"好的，马上打开八号爆闪"}
  //{ID:84,keyword:"命令词",ASR:"关闭八号灯",ASRTO:"好的，马上关闭八号灯"}
  //{ID:85,keyword:"命令词",ASR:"打开八号灯",ASRTO:"好的，马上打开八号灯"}
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
