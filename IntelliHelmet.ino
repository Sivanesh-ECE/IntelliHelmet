/*
  ============================================================================
  SMART HELMET — FIRMWARE v4 (BLE GATT + SOS Notification)
  ============================================================================
  ARCHITECTURE CHANGE from v3:
    v3 used BLE HID Keyboard — could only TYPE text, could NOT trigger app logic.
    v4 uses BLE GATT Server — sends a UUID notification to the Flutter app,
    which then reads GPS and sends the real SOS SMS with live location.

  BLE GATT UUIDs (must match Flutter app exactly):
    Service  : 12345678-1234-1234-1234-123456789012
    SOS Char : 12345678-1234-1234-1234-123456789013  (NOTIFY)
    ACK Char : 12345678-1234-1234-1234-123456789014  (WRITE — app cancels SOS)

  TRIGGERS:
    - 5s sustained vibration (MPU6050)
    - Loud shout (INMP441 mic)
    - Manual SOS button press

  HARDWARE:
    MPU6050  : SDA->D21, SCL->D22, ADO->GND  (I2C addr 0x68)
    SSD1306  : SDA->D21, SCL->D22            (I2C addr 0x3C)
    MAX98357A: DIN->D14, BCLK->D27, LRC->D32 (I2S_NUM_0)
    INMP441  : WS->D25, SCK->D26, SD->D33, L/R->GND (I2S_NUM_1)
    SOS BTN  : D18 -> GND
    MODE BTN : D19 -> GND

  REQUIRED LIBRARIES (Library Manager):
    - Adafruit GFX Library
    - Adafruit SSD1306
    - ESP32 BLE Arduino (built-in with ESP32 board package)

  TUNING (Serial Monitor @ 115200):
    [MPU] jerk=X  -> shake hard, set ACCEL_JERK_THRESHOLD_G below that X
    [MIC] rms=X   -> shout loudly, set LOUD_RMS_THRESHOLD below that X
  ============================================================================
*/

#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include "driver/i2s.h"

// ============================================================================
// BLE UUIDs — must match Flutter app exactly
// ============================================================================
#define SERVICE_UUID        "12345678-1234-1234-1234-123456789012"
#define SOS_CHAR_UUID       "12345678-1234-1234-1234-123456789013"  // NOTIFY → app
#define ACK_CHAR_UUID       "12345678-1234-1234-1234-123456789014"  // WRITE  ← app

// ============================================================================
// HARDWARE PIN DEFINITIONS
// ============================================================================
#define SCREEN_WIDTH     128
#define SCREEN_HEIGHT    64
#define OLED_RESET       -1

#define MPU6050_ADDR     0x68
#define REG_PWR_MGMT_1   0x6B
#define REG_GYRO_CONFIG  0x1B
#define REG_ACCEL_CONFIG 0x1C
#define REG_ACCEL_XOUT_H 0x3B

#define SOS_BUTTON_PIN   18
#define MODE_BUTTON_PIN  19

#define SPK_BCLK_PIN     27
#define SPK_LRC_PIN      32
#define SPK_DOUT_PIN     14
#define SPK_I2S_PORT     I2S_NUM_0
#define SPK_SAMPLE_RATE  16000

#define MIC_WS_PIN       25
#define MIC_SCK_PIN      26
#define MIC_SD_PIN       33
#define MIC_I2S_PORT     I2S_NUM_1
#define MIC_SAMPLE_RATE  16000
#define MIC_BUFFER_LEN   512

// ============================================================================
// TUNABLE THRESHOLDS
// ============================================================================
const float          ACCEL_JERK_THRESHOLD_G = 0.5;
const unsigned long  JERK_GAP_TOLERANCE_MS  = 800;
const unsigned long  VIBRATION_DURATION_MS  = 5000;
const float          LOUD_RMS_THRESHOLD     = 3000.0;
const unsigned long  LOUD_SUSTAIN_MS        = 400;
const unsigned long  LOUD_GAP_TOLERANCE_MS  = 250;
const unsigned long  COUNTDOWN_MS           = 5000;
const unsigned long  EMERGENCY_COOLDOWN_MS  = 15000;
const unsigned long  BT_RESEND_MS           = 8000;
const float          ACCEL_SENSITIVITY      = 4096.0;
const float          GYRO_SENSITIVITY       = 65.5;

// ============================================================================
// BLE GLOBALS
// ============================================================================
BLEServer*           pServer        = nullptr;
BLECharacteristic*   pSosChar       = nullptr;
BLECharacteristic*   pAckChar       = nullptr;
bool                 bleConnected   = false;
bool                 bleWasConnected = false;

// ============================================================================
// BLE SERVER CALLBACKS — track connect/disconnect
// ============================================================================
class HelmetServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pSvr) override {
    bleConnected = true;
    Serial.println("[BLE] Phone connected.");
  }
  void onDisconnect(BLEServer* pSvr) override {
    bleConnected    = false;
    bleWasConnected = true;
    Serial.println("[BLE] Phone disconnected. Restarting advertising...");
    BLEDevice::startAdvertising();
  }
};

// ============================================================================
// ACK CHARACTERISTIC CALLBACKS — phone writes "CANCEL" to cancel SOS
// ============================================================================
class AckCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pChar) override {
    String val = pChar->getValue().c_str();
    Serial.print("[BLE] ACK received from phone: "); Serial.println(val);
    if (val == "CANCEL") {
      // Phone-side user cancelled SOS (e.g. tapped "I'm OK" in app)
      extern void exitEmergency();
      exitEmergency();
    }
  }
};

// ============================================================================
// OTHER OBJECTS & STATE
// ============================================================================
Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);
int32_t          micBuffer[MIC_BUFFER_LEN];

enum SystemState { STATE_MONITORING, STATE_COUNTDOWN, STATE_EMERGENCY };
SystemState currentState = STATE_MONITORING;

float         lastAccelMagG      = 1.0;
unsigned long lastJerkTime        = 0;
unsigned long irregularStartTime  = 0;
bool          irregularOngoing    = false;
int           mpuFailCount        = 0;

bool          loudOngoing         = false;
unsigned long loudStartTime       = 0;
unsigned long lastLoudTime        = 0;

unsigned long countdownStartTime  = 0;
unsigned long lastEmergencyTime   = 0;
unsigned long lastOledUpdate      = 0;
unsigned long lastBtAlertSent     = 0;
unsigned long lastDebugPrint      = 0;
unsigned long lastMicDebug        = 0;
int           lastRemainingShown  = -1;

bool alarmMuted    = false;
bool lastSosState  = HIGH;
bool lastModeState = HIGH;

// ============================================================================
// FORWARD DECLARATIONS
// ============================================================================
bool mpuWriteRegister(uint8_t reg, uint8_t value);
bool initMPU6050();
bool readMPU6050(float &accelMagG, float &gyroMagDps);
void monitorAccident();
void checkMicrophoneShout();
void enterCountdown();
void runCountdown();
void cancelCountdown();
void enterEmergency();
void runEmergency();
void exitEmergency();
void sendSOSAlert();
void handleButtons();
void onSosButtonPressed();
void onModeButtonPressed();
void setupBLE();
void speakerI2sSetup();
void playTone(float frequency, int durationMs);
void micI2sSetup();
void showBootScreen();
void showMessage(const char* line1, const char* line2);
void showMonitoringScreen(const char* status);
void showCountdownScreen(int seconds);
void showEmergencyScreen();

// ============================================================================
// SETUP
// ============================================================================
void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println("Smart Helmet v4 booting...");

  lastEmergencyTime = millis() - EMERGENCY_COOLDOWN_MS - 1000;

  pinMode(SOS_BUTTON_PIN,  INPUT_PULLUP);
  pinMode(MODE_BUTTON_PIN, INPUT_PULLUP);

  Wire.begin(21, 22);
  Wire.setTimeOut(1000);

  if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
    Serial.println("OLED FAILED");
  }
  showBootScreen();
  delay(800);

  // ---- BLE GATT Server ----
  showMessage("BLE Starting...", "Please wait");
  setupBLE();
  showMessage("BLE Advertising", "Open SmartHelmet app");
  delay(800);

  // ---- MPU6050 ----
  showMessage("MPU6050", "Initializing...");
  delay(300);
  bool mpuOk = false;
  for (int attempt = 1; attempt <= 5 && !mpuOk; attempt++) {
    mpuOk = initMPU6050();
    if (!mpuOk) { Serial.printf("MPU attempt %d failed\n", attempt); delay(300); }
  }
  if (!mpuOk) {
    showMessage("MPU6050 ERROR", "Check wiring");
    while (1) delay(1000);
  }
  Serial.println("MPU6050 ready.");

  speakerI2sSetup();
  micI2sSetup();

  showMonitoringScreen("System Ready");
  Serial.println("=== Smart Helmet v4 running ===");
}

// ============================================================================
// MAIN LOOP
// ============================================================================
void loop() {
  handleButtons();
  checkMicrophoneShout();

  switch (currentState) {
    case STATE_MONITORING: monitorAccident(); break;
    case STATE_COUNTDOWN:  runCountdown();    break;
    case STATE_EMERGENCY:  runEmergency();    break;
  }

  delay(10);
}

// ============================================================================
// BLE GATT SETUP
// ============================================================================
void setupBLE() {
  BLEDevice::init("SmartHelmet");
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new HelmetServerCallbacks());

  BLEService* pService = pServer->createService(SERVICE_UUID);

  // SOS characteristic — ESP32 notifies app when accident detected
  pSosChar = pService->createCharacteristic(
    SOS_CHAR_UUID,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pSosChar->addDescriptor(new BLE2902()); // enables notifications on client

  // ACK characteristic — app writes back to cancel SOS
  pAckChar = pService->createCharacteristic(
    ACK_CHAR_UUID,
    BLECharacteristic::PROPERTY_WRITE
  );
  pAckChar->setCallbacks(new AckCallbacks());

  pService->start();

  BLEAdvertising* pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);
  BLEDevice::startAdvertising();

  Serial.println("[BLE] GATT server started. Advertising as 'SmartHelmet'.");
}

// ============================================================================
// SEND SOS NOTIFICATION TO PHONE
// ============================================================================
void sendSOSAlert() {
  if (bleConnected && pSosChar != nullptr) {
    // Send "SOS" string — Flutter app receives this and triggers SMS + location
    pSosChar->setValue("SOS");
    pSosChar->notify();
    Serial.println("[BLE] SOS notification sent to phone.");
  } else {
    Serial.println("[BLE] NOT connected — alert NOT sent. Open SmartHelmet app!");
  }
}

// ============================================================================
// MPU6050
// ============================================================================
bool mpuWriteRegister(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(MPU6050_ADDR);
  Wire.write(reg);
  Wire.write(value);
  return (Wire.endTransmission() == 0);
}

bool initMPU6050() {
  bool ok = true;
  ok &= mpuWriteRegister(REG_PWR_MGMT_1,   0x00);
  delay(50);
  ok &= mpuWriteRegister(REG_GYRO_CONFIG,  0x08);
  ok &= mpuWriteRegister(REG_ACCEL_CONFIG, 0x10);
  return ok;
}

bool readMPU6050(float &accelMagG, float &gyroMagDps) {
  Wire.beginTransmission(MPU6050_ADDR);
  Wire.write(REG_ACCEL_XOUT_H);
  if (Wire.endTransmission(false) != 0) return false;
  uint8_t n = Wire.requestFrom((uint8_t)MPU6050_ADDR, (uint8_t)14, (uint8_t)true);
  if (n < 14) return false;

  int16_t axR = (Wire.read() << 8) | Wire.read();
  int16_t ayR = (Wire.read() << 8) | Wire.read();
  int16_t azR = (Wire.read() << 8) | Wire.read();
  Wire.read(); Wire.read();
  int16_t gxR = (Wire.read() << 8) | Wire.read();
  int16_t gyR = (Wire.read() << 8) | Wire.read();
  int16_t gzR = (Wire.read() << 8) | Wire.read();

  float ax = axR / ACCEL_SENSITIVITY, ay = ayR / ACCEL_SENSITIVITY, az = azR / ACCEL_SENSITIVITY;
  accelMagG = sqrt(ax*ax + ay*ay + az*az);
  float gx = gxR / GYRO_SENSITIVITY, gy = gyR / GYRO_SENSITIVITY, gz = gzR / GYRO_SENSITIVITY;
  gyroMagDps = sqrt(gx*gx + gy*gy + gz*gz);
  return true;
}

// ============================================================================
// ACCIDENT DETECTION
// ============================================================================
void monitorAccident() {
  float accelMagG, gyroMagDps;
  if (!readMPU6050(accelMagG, gyroMagDps)) {
    if (++mpuFailCount >= 10) {
      if (initMPU6050()) { mpuFailCount = 0; Serial.println("[MPU] Re-init OK"); }
    }
    return;
  }
  mpuFailCount = 0;

  float jerk = fabs(accelMagG - lastAccelMagG);
  lastAccelMagG = accelMagG;
  unsigned long now = millis();

  if (now - lastDebugPrint > 300) {
    Serial.printf("[MPU] accel=%.3fg  jerk=%.3fg  gyro=%.1fdps\n", accelMagG, jerk, gyroMagDps);
    lastDebugPrint = now;
  }

  if (jerk > ACCEL_JERK_THRESHOLD_G) {
    lastJerkTime = now;
    if (!irregularOngoing) {
      irregularOngoing = true; irregularStartTime = now;
      Serial.println("[MPU] Vibration STARTED");
    }
  } else if (irregularOngoing && (now - lastJerkTime > JERK_GAP_TOLERANCE_MS)) {
    irregularOngoing = false;
    Serial.println("[MPU] Vibration settled — timer reset");
  }

  if ((now - lastEmergencyTime > EMERGENCY_COOLDOWN_MS) && irregularOngoing &&
      (now - irregularStartTime >= VIBRATION_DURATION_MS)) {
    Serial.println("[MPU] 5s vibration — ACCIDENT DETECTED");
    irregularOngoing = false;
    enterCountdown();
    return;
  }

  if (now - lastOledUpdate > 500) {
    showMonitoringScreen(irregularOngoing
      ? ("Vibration " + String((now - irregularStartTime) / 1000) + "s").c_str()
      : (alarmMuted ? "Monitoring(Muted)" : "Monitoring..."));
    lastOledUpdate = now;
  }
}

// ============================================================================
// MICROPHONE
// ============================================================================
void checkMicrophoneShout() {
  size_t bytesRead = 0;
  i2s_read(MIC_I2S_PORT, micBuffer, sizeof(micBuffer), &bytesRead, 2 / portTICK_PERIOD_MS);
  int samplesRead = bytesRead / sizeof(int32_t);
  if (samplesRead < 2) return;

  int64_t sumSquares = 0; int count = 0;
  for (int i = 0; i + 1 < samplesRead; i += 2) {
    int32_t s = micBuffer[i + 1] >> 11;
    sumSquares += (int64_t)s * s; count++;
  }
  if (!count) return;
  float rms = sqrt((float)sumSquares / count);

  unsigned long now = millis();
  if (now - lastMicDebug > 300) { Serial.printf("[MIC] rms=%.1f\n", rms); lastMicDebug = now; }

  if (rms > LOUD_RMS_THRESHOLD) {
    lastLoudTime = now;
    if (!loudOngoing) { loudOngoing = true; loudStartTime = now; Serial.println("[MIC] Loud STARTED"); }
    if (currentState == STATE_MONITORING && (now - loudStartTime >= LOUD_SUSTAIN_MS)) {
      Serial.println("[MIC] Sustained shout — SOS triggered");
      loudOngoing = false; enterCountdown();
    }
  } else if (loudOngoing && (now - lastLoudTime > LOUD_GAP_TOLERANCE_MS)) {
    loudOngoing = false;
  }
}

// ============================================================================
// COUNTDOWN
// ============================================================================
void enterCountdown() {
  currentState = STATE_COUNTDOWN;
  countdownStartTime = millis();
  lastRemainingShown = -1;
  showCountdownScreen(5);
  Serial.println("COUNTDOWN — press SOS to cancel");
}

void runCountdown() {
  unsigned long elapsed = millis() - countdownStartTime;
  int remaining = 5 - (int)(elapsed / 1000);
  if (remaining < 0) remaining = 0;
  if (remaining != lastRemainingShown) {
    showCountdownScreen(remaining);
    lastRemainingShown = remaining;
    if (!alarmMuted) playTone(1500, 80);
    Serial.printf("Countdown: %d\n", remaining);
  }
  if (elapsed >= COUNTDOWN_MS) enterEmergency();
}

void cancelCountdown() {
  currentState = STATE_MONITORING;
  Serial.println("Countdown CANCELLED");
  showMonitoringScreen("SOS Cancelled");
  delay(800);
}

// ============================================================================
// EMERGENCY
// ============================================================================
void enterEmergency() {
  currentState = STATE_EMERGENCY;
  lastEmergencyTime = millis();
  showEmergencyScreen();
  sendSOSAlert();
  lastBtAlertSent = millis();
  Serial.println("EMERGENCY ACTIVE");
}

void runEmergency() {
  unsigned long now = millis();
  if (now - lastOledUpdate > 1000) { showEmergencyScreen(); lastOledUpdate = now; }
  if (now - lastBtAlertSent > BT_RESEND_MS) { sendSOSAlert(); lastBtAlertSent = now; }
  if (!alarmMuted) { playTone(1000, 150); playTone(700, 150); }
  else delay(300);
  handleButtons();
}

void exitEmergency() {
  currentState = STATE_MONITORING;
  lastEmergencyTime = millis();
  Serial.println("Emergency cleared");
  showMonitoringScreen("Cleared");
  delay(800);
}

// ============================================================================
// BUTTONS
// ============================================================================
void handleButtons() {
  bool sosState  = digitalRead(SOS_BUTTON_PIN);
  bool modeState = digitalRead(MODE_BUTTON_PIN);

  if (lastSosState == HIGH && sosState == LOW)   { delay(50); onSosButtonPressed(); }
  lastSosState = sosState;
  if (lastModeState == HIGH && modeState == LOW) { delay(50); onModeButtonPressed(); }
  lastModeState = modeState;
}

void onSosButtonPressed() {
  switch (currentState) {
    case STATE_MONITORING: enterCountdown();  break;
    case STATE_COUNTDOWN:  cancelCountdown(); break;
    case STATE_EMERGENCY:  exitEmergency();   break;
  }
}

void onModeButtonPressed() {
  alarmMuted = !alarmMuted;
  Serial.printf("[BTN] Muted: %s\n", alarmMuted ? "YES" : "NO");
  if (currentState == STATE_MONITORING)
    showMonitoringScreen(alarmMuted ? "Alarm: MUTED" : "Alarm: ON");
}

// ============================================================================
// I2S SPEAKER
// ============================================================================
void speakerI2sSetup() {
  i2s_config_t cfg = {
    .mode=(i2s_mode_t)(I2S_MODE_MASTER|I2S_MODE_TX), .sample_rate=SPK_SAMPLE_RATE,
    .bits_per_sample=I2S_BITS_PER_SAMPLE_16BIT, .channel_format=I2S_CHANNEL_FMT_RIGHT_LEFT,
    .communication_format=I2S_COMM_FORMAT_STAND_I2S, .intr_alloc_flags=ESP_INTR_FLAG_LEVEL1,
    .dma_buf_count=8, .dma_buf_len=256, .use_apll=false, .tx_desc_auto_clear=true, .fixed_mclk=0
  };
  i2s_driver_install(SPK_I2S_PORT, &cfg, 0, NULL);
  i2s_pin_config_t pins = {
    .mck_io_num=I2S_PIN_NO_CHANGE, .bck_io_num=SPK_BCLK_PIN,
    .ws_io_num=SPK_LRC_PIN, .data_out_num=SPK_DOUT_PIN, .data_in_num=I2S_PIN_NO_CHANGE
  };
  i2s_set_pin(SPK_I2S_PORT, &pins);
}

void playTone(float frequency, int durationMs) {
  const int bufferLen = 256;
  static int16_t buffer[bufferLen * 2];
  int totalSamples = (SPK_SAMPLE_RATE * durationMs) / 1000, samplesWritten = 0;
  size_t bytesWritten;
  static float phase = 0.0;
  float phaseInc = 2.0 * PI * frequency / SPK_SAMPLE_RATE;
  while (samplesWritten < totalSamples) {
    int chunk = min(bufferLen, totalSamples - samplesWritten);
    for (int i = 0; i < chunk; i++) {
      int16_t s = (int16_t)(9000.0 * sin(phase));
      buffer[i*2] = buffer[i*2+1] = s;
      phase += phaseInc;
      if (phase > 2.0 * PI) phase -= 2.0 * PI;
    }
    i2s_write(SPK_I2S_PORT, buffer, chunk*2*sizeof(int16_t), &bytesWritten, portMAX_DELAY);
    samplesWritten += chunk;
  }
}

// ============================================================================
// I2S MICROPHONE
// ============================================================================
void micI2sSetup() {
  i2s_config_t cfg = {
    .mode=(i2s_mode_t)(I2S_MODE_MASTER|I2S_MODE_RX), .sample_rate=MIC_SAMPLE_RATE,
    .bits_per_sample=I2S_BITS_PER_SAMPLE_32BIT, .channel_format=I2S_CHANNEL_FMT_RIGHT_LEFT,
    .communication_format=I2S_COMM_FORMAT_STAND_I2S, .intr_alloc_flags=ESP_INTR_FLAG_LEVEL1,
    .dma_buf_count=4, .dma_buf_len=256, .use_apll=false, .tx_desc_auto_clear=false, .fixed_mclk=0
  };
  i2s_driver_install(MIC_I2S_PORT, &cfg, 0, NULL);
  i2s_pin_config_t pins = {
    .mck_io_num=I2S_PIN_NO_CHANGE, .bck_io_num=MIC_SCK_PIN,
    .ws_io_num=MIC_WS_PIN, .data_out_num=I2S_PIN_NO_CHANGE, .data_in_num=MIC_SD_PIN
  };
  i2s_set_pin(MIC_I2S_PORT, &pins);
}

// ============================================================================
// OLED SCREENS
// ============================================================================
void showBootScreen() {
  display.clearDisplay(); display.setTextColor(SSD1306_WHITE); display.setTextSize(1);
  display.setCursor(10,15); display.println("SMART HELMET");
  display.setCursor(10,30); display.println("SYSTEM ACTIVE");
  display.setCursor(5,50);  display.println("Initializing...");
  display.display();
}

void showMessage(const char* line1, const char* line2) {
  display.clearDisplay(); display.setTextColor(SSD1306_WHITE); display.setTextSize(1);
  display.setCursor(0,20); display.println(line1);
  display.setCursor(0,38); display.println(line2);
  display.display();
}

void showMonitoringScreen(const char* status) {
  display.clearDisplay(); display.setTextColor(SSD1306_WHITE); display.setTextSize(1);
  display.setCursor(0,0);  display.println("SMART HELMET");
  display.drawLine(0,10,128,10,SSD1306_WHITE);
  display.setCursor(0,18); display.println(status);
  display.setCursor(0,40); display.print("BLE: ");
  display.println(bleConnected ? "Connected" : "Waiting...");
  display.display();
}

void showCountdownScreen(int seconds) {
  display.clearDisplay(); display.setTextColor(SSD1306_WHITE);
  display.setTextSize(1);
  display.setCursor(0,0);  display.println("ACCIDENT DETECTED!");
  display.setCursor(0,14); display.println("SOS in:");
  display.setTextSize(4);
  display.setCursor(50,24); display.print(seconds > 0 ? seconds : 0);
  display.setTextSize(1);
  display.setCursor(0,56); display.println("Press SOS to cancel");
  display.display();
}

void showEmergencyScreen() {
  display.clearDisplay(); display.setTextColor(SSD1306_WHITE); display.setTextSize(1);
  display.setCursor(0,0);  display.println("** EMERGENCY **");
  display.drawLine(0,10,128,10,SSD1306_WHITE);
  display.setCursor(0,18); display.println("SOS sent to phone");
  display.setCursor(0,32); display.print("BLE: ");
  display.println(bleConnected ? "Connected" : "Disconnected!");
  display.setCursor(0,50); display.println("Press SOS to clear");
  display.display();
}
