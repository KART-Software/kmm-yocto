// XPI-i.MX8MM の A コア / M コアの各 UART コンソールを、Teensy 4.0 を介して
// PC からは独立した 2 本の USB CDC シリアルデバイスとして見せるブリッジ。
//
// 配線 (すべて 3.3V ロジック、GND 共通):
//   Serial1: RX1 = pin 0, TX1 = pin 1  <->  A コア UART (TX->RX1, RX<-TX1)
//   Serial2: RX2 = pin 7, TX2 = pin 8  <->  M コア UART (TX->RX2, RX<-TX2)
//
// PC 側で開いたボーレート (CDC line coding) がそのままハードウェア UART に
// 反映されるので、picocom/minicom の -b 指定だけで両側の速度が揃う。

#include <Arduino.h>

#if !defined(USB_DUAL_SERIAL) && !defined(USB_TRIPLE_SERIAL)
#error "Build with -D USB_DUAL_SERIAL (platformio.ini の build_flags を確認)"
#endif

static constexpr uint32_t DEFAULT_BAUD = 115200;

// USB 側が詰まっている間も UART 受信を取りこぼさないよう受信バッファを拡張
static uint8_t uart1RxBuf[4096];
static uint8_t uart2RxBuf[4096];

static uint32_t baudA = 0;  // Serial1 に設定済みのボーレート
static uint32_t baudM = 0;  // Serial2 に設定済みのボーレート

static elapsedMillis sinceActivity;

// ホストが CDC ポートに設定したボーレートを対応する UART へ追従させる
template <typename UsbSerial>
static void syncBaud(UsbSerial &usb, HardwareSerial &uart, uint32_t &current) {
  uint32_t b = usb.baud();
  if (b == 0) {
    b = DEFAULT_BAUD;  // ホスト未接続 or line coding 未設定
  }
  if (b != current) {
    current = b;
    uart.begin(b);
  }
}

// src -> dst へ、双方の空きに収まる分だけまとめて転送する
static size_t pump(Stream &src, Stream &dst) {
  int n = src.available();
  if (n <= 0) {
    return 0;
  }
  int space = dst.availableForWrite();
  if (space <= 0) {
    return 0;
  }
  uint8_t buf[512];
  if (n > space) n = space;
  if (n > (int)sizeof(buf)) n = (int)sizeof(buf);
  n = (int)src.readBytes((char *)buf, n);
  if (n > 0) {
    dst.write(buf, n);
  }
  return (size_t)n;
}

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);

  Serial1.addMemoryForRead(uart1RxBuf, sizeof(uart1RxBuf));
  Serial2.addMemoryForRead(uart2RxBuf, sizeof(uart2RxBuf));
  Serial1.begin(DEFAULT_BAUD);
  Serial2.begin(DEFAULT_BAUD);
  baudA = DEFAULT_BAUD;
  baudM = DEFAULT_BAUD;
}

void loop() {
  syncBaud(Serial, Serial1, baudA);
  syncBaud(SerialUSB1, Serial2, baudM);

  size_t moved = 0;
  moved += pump(Serial, Serial1);      // PC -> A コア
  moved += pump(Serial1, Serial);      // A コア -> PC
  moved += pump(SerialUSB1, Serial2);  // PC -> M コア
  moved += pump(Serial2, SerialUSB1);  // M コア -> PC

  if (moved > 0) {
    sinceActivity = 0;
  }
  // 通信中は LED 点灯 (消灯まで 50ms ホールド)
  digitalWrite(LED_BUILTIN, sinceActivity < 50 ? HIGH : LOW);
}
