import 'dart:typed_data';

import 'package:companion_client/companion_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/services/cli_service.dart';
import 'package:meshcore_repeater_manager/services/request_meter.dart';
import 'support.dart';

void main() {
  group('RequestMeter', () {
    test('counts requests and reports an opt-in budget', () {
      final meter = RequestMeter();
      expect(meter.count, 0);
      expect(meter.overBudget, isFalse);
      meter.record();
      meter.record(2);
      expect(meter.count, 3);
      meter.setBudget(3);
      expect(meter.overBudget, isTrue);
      meter.setBudget(4);
      expect(meter.overBudget, isFalse);
      meter.setBudget(0); // clamped to 1
      expect(meter.budget, 1);
      meter.setBudget(null);
      expect(meter.overBudget, isFalse);
      meter.reset();
      expect(meter.count, 0);
    });

    test('a listener sees count changes', () {
      final meter = RequestMeter();
      var notified = 0;
      meter.addListener(() => notified++);
      meter.record();
      meter.reset();
      expect(notified, 2);
    });
  });

  test('CliService counts each exchange, including a read retry', () async {
    var attempts = 0;
    late final RequestMeter meter;
    final cli = CliService(
      exchange: (_, command, {timeout = const Duration(seconds: 45)}) async {
        attempts++;
        if (attempts == 1) throw CompanionTimeoutException('lost');
        return '> ok';
      },
      binary: (_, __,
              {data = const [],
              required exactLength,
              timeout = const Duration(seconds: 10)}) async =>
          Uint8List(exactLength),
      rawBinary: (_, __,
              {data = const [], timeout = const Duration(seconds: 10)}) async =>
          Uint8List(4),
      onRequest: () => meter.record(),
    );
    meter = RequestMeter();

    await cli.read(contact('Roof'), 'ver');
    expect(meter.count, 2);
    await cli.status(contact('Roof'));
    expect(meter.count, 3);
    await cli.owner(contact('Roof'));
    expect(meter.count, 4);
  });
}
