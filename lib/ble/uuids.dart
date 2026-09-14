/// BLE GATT contract with the PixelCore75 firmware.
///
/// Every UUID here must match the corresponding `CHARACTERISTIC_UUID_*`
/// define in `pixelcore75-firmware/src/main.cpp` byte-for-byte.
/// Changing one side without the other breaks provisioning.
library;

const String kTargetServiceUuid = '975a3183-e5f1-448a-acab-2016d89c1fe7';

const String kUuidHostname = '38487a5b-f731-4118-bf66-4ee253d5f664';
const String kUuidServerPort = 'e67e6360-99f3-4c6b-8e60-2e9266100718';
const String kUuidWifiSsid = '7a034f21-a679-4d51-a284-e6b4b69ceea9';
const String kUuidWifiPassword = '3f007796-2fd1-42d2-b122-458f1f0b90bf';
const String kUuidBrightness = 'a7423ece-dced-4fb2-ac67-ddf97323726b';
const String kUuidRestart = '81ed8290-f167-47b9-b183-2f248c543889';

const Map<String, String> kCharNames = {
  kUuidHostname: 'Server hostname',
  kUuidServerPort: 'Server port',
  kUuidWifiSsid: 'Wifi SSID',
  kUuidWifiPassword: 'Wifi password',
  kUuidBrightness: 'Brightness',
  kUuidRestart: 'Restart device',
};

/// Normalizes a UUID string (e.g. from discovery) so it can be compared
/// against the constants above.
String normalizeUuid(String uuid) => uuid.toLowerCase();
