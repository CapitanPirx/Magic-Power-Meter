#include <Wire.h>
#include <Adafruit_INA219.h>

Adafruit_INA219 ina219;

int measurementCount = 0;

static void printFloatComma(float value, uint8_t decimals) {
  char buf[20];
  // dtostrf(value, width, precision, buf)
  // width = 0 (минимальная ширина), precision = decimals
  dtostrf(value, 0, decimals, buf);

  // заменить '.' на ','
  for (char *p = buf; *p; p++) {
    if (*p == '.') *p = ',';
  }

  Serial.print(buf);
}

void setup() {
  Serial.begin(9600);
  while (!Serial) { delay(10); }

  if (!ina219.begin()) {
    Serial.println("ERROR");
    while (1) { delay(1000); }
  }

  ina219.setCalibration_32V_2A();

  // Заголовки CSV-подобные (разделитель ;)
  Serial.println("count;voltage_V;current_mA;power_W");
}

void loop() {
  float voltage = ina219.getBusVoltage_V();
  float current = ina219.getCurrent_mA();
  float power   = voltage * current / 1000.0f;

  measurementCount++;

  Serial.print(measurementCount);
  Serial.print(';');
  printFloatComma(voltage, 2);
  Serial.print(';');
  printFloatComma(current, 2);
  Serial.print(';');
  printFloatComma(power, 3);
  Serial.println();

  delay(1000);
}