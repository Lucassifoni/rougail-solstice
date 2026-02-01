#define AXIS_COUNT 3
#define PACKET_SIZE 5
#define BAUD_RATE 115200
#define WATCHDOG_TIMEOUT_MS 500
#define SYNC_BYTE 0xAA
#define PACKET_TIMEOUT_US 50000

#define MIN_INTERVAL_US 100
#define MAX_INTERVAL_US 5000
#define STEP_PULSE_US 2
#define MAX_CATCHUP_US 50000

struct AxisPins {
  uint8_t step;
  uint8_t dir;
  uint8_t enable;
};

struct AxisState {
  bool enabled;
  bool direction;
  uint8_t speed;
  unsigned long nextStepTime;
  bool pulseActive;
  unsigned long pulseEndTime;
};

const AxisPins pins[AXIS_COUNT] = {
  {2, 3, 4},
  {5, 6, 7},
  {8, 9, 10}
};

AxisState axes[AXIS_COUNT];
unsigned long lastPacketTime = 0;
unsigned long lastByteTime = 0;
uint8_t packetBuffer[PACKET_SIZE];
uint8_t bufferIndex = 0;
bool allDisabled = true;

void disableAll() {
  if (allDisabled) return;
  for (uint8_t i = 0; i < AXIS_COUNT; i++) {
    axes[i].enabled = false;
    axes[i].speed = 0;
    axes[i].pulseActive = false;
    digitalWrite(pins[i].step, LOW);
    digitalWrite(pins[i].enable, HIGH);
  }
  allDisabled = true;
}

void applyPacket() {
  uint8_t flags = packetBuffer[1];
  unsigned long now = micros();

  for (uint8_t i = 0; i < AXIS_COUNT; i++) {
    uint8_t shift = 6 - (i * 2);
    bool enabled = (flags >> (shift + 1)) & 0x01;
    bool direction = (flags >> shift) & 0x01;
    uint8_t speed = packetBuffer[2 + i];

    bool wasEnabled = axes[i].enabled;
    axes[i].enabled = enabled && speed > 0;
    axes[i].direction = direction;
    axes[i].speed = speed;

    digitalWrite(pins[i].dir, direction ? HIGH : LOW);
    digitalWrite(pins[i].enable, axes[i].enabled ? LOW : HIGH);

    if (axes[i].enabled && !wasEnabled) {
      axes[i].nextStepTime = now;
    }
  }

  allDisabled = !(axes[0].enabled || axes[1].enabled || axes[2].enabled);
}

unsigned long speedToInterval(uint8_t speed) {
  if (speed == 0) return 0;
  return map(speed, 1, 255, MAX_INTERVAL_US, MIN_INTERVAL_US);
}

void setup() {
  Serial.begin(BAUD_RATE);

  for (uint8_t i = 0; i < AXIS_COUNT; i++) {
    pinMode(pins[i].step, OUTPUT);
    pinMode(pins[i].dir, OUTPUT);
    pinMode(pins[i].enable, OUTPUT);
    digitalWrite(pins[i].step, LOW);
    digitalWrite(pins[i].dir, LOW);
    digitalWrite(pins[i].enable, HIGH);
    axes[i].enabled = false;
    axes[i].direction = false;
    axes[i].speed = 0;
    axes[i].nextStepTime = 0;
    axes[i].pulseActive = false;
    axes[i].pulseEndTime = 0;
  }

  lastPacketTime = millis();
  lastByteTime = micros();
}

void loop() {
  unsigned long now = micros();

  if (bufferIndex > 0 && (now - lastByteTime) > PACKET_TIMEOUT_US) {
    bufferIndex = 0;
  }

  while (Serial.available() > 0) {
    uint8_t b = Serial.read();
    lastByteTime = micros();

    if (bufferIndex == 0) {
      if (b == SYNC_BYTE) {
        packetBuffer[0] = b;
        bufferIndex = 1;
      }
      continue;
    }

    if (bufferIndex < PACKET_SIZE) {
      packetBuffer[bufferIndex++] = b;
    }

    if (bufferIndex >= PACKET_SIZE) {
      applyPacket();
      lastPacketTime = millis();
      bufferIndex = 0;
    }
  }

  if (millis() - lastPacketTime > WATCHDOG_TIMEOUT_MS) {
    disableAll();
    lastPacketTime = millis();
  }

  now = micros();
  for (uint8_t i = 0; i < AXIS_COUNT; i++) {
    if (axes[i].pulseActive) {
      if ((long)(now - axes[i].pulseEndTime) >= 0) {
        digitalWrite(pins[i].step, LOW);
        axes[i].pulseActive = false;
      }
      continue;
    }

    if (!axes[i].enabled || axes[i].speed == 0) continue;

    if ((long)(now - axes[i].nextStepTime) >= 0) {
      unsigned long interval = speedToInterval(axes[i].speed);

      if ((now - axes[i].nextStepTime) > MAX_CATCHUP_US) {
        axes[i].nextStepTime = now;
      }

      digitalWrite(pins[i].step, HIGH);
      axes[i].pulseActive = true;
      axes[i].pulseEndTime = now + STEP_PULSE_US;
      axes[i].nextStepTime += interval;
    }
  }
}
