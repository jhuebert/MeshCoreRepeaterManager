// The curated, safe subset of settings that may be changed across a fleet.
// Secrets, keys and one-shot effects are deliberately absent.

import 'setting_spec.dart';

const bulkSafeKeys = <String>[
  'name',
  'lat',
  'lon',
  'owner.info',
  'allow.read.only',
  'repeat',
  'loop.detect',
  'multi.acks',
  'advert.interval',
  'flood.max',
  'flood.max.advert',
  'path.hash.mode',
  'txdelay',
  'direct.txdelay',
  'rxdelay',
];

List<SettingSpec> get bulkSafeSettings =>
    bulkSafeKeys.map(settingFor).whereType<SettingSpec>().toList();

/// Validate one bulk value against its spec before a script is built.
String? validateBulkValue(String key, String value) {
  final spec = settingFor(key);
  if (spec == null || !bulkSafeKeys.contains(key)) {
    return 'This setting is not safe to change across a fleet';
  }
  return spec.validate(value);
}

/// The `set` lines of a bulk job, in a stable order.
List<String> bulkSetLines(Map<String, String> values) => bulkSafeKeys
    .where(values.containsKey)
    .map((key) => 'set $key ${values[key]}')
    .toList();
