import 'package:repeater_core/repeater_core.dart';
import 'package:test/test.dart';

void main() {
  test('the curated subset excludes secrets and destructive keys', () {
    expect(bulkSafeKeys, isNot(contains('password')));
    expect(bulkSafeKeys, isNot(contains('guest.password')));
    expect(bulkSafeKeys, isNot(contains('radio')));
    expect(bulkSafeSettings, hasLength(bulkSafeKeys.length));
    for (final spec in bulkSafeSettings) {
      expect(spec.secret, isFalse);
    }
  });

  test('values are validated against the shared spec', () {
    expect(validateBulkValue('tx', '20'), contains('not safe'));
    expect(validateBulkValue('repeat', 'on'), isNull);
    expect(validateBulkValue('advert.interval', '-1'), contains('at least'));
    expect(validateBulkValue('name', ''), contains('Enter a value'));
  });

  test('set lines follow a stable order', () {
    final lines =
        bulkSetLines({'repeat': 'on', 'name': 'Roof', 'txdelay': '5'});
    expect(lines, ['set name Roof', 'set repeat on', 'set txdelay 5']);
  });
}
