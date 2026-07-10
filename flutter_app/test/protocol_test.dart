import 'package:flutter_test/flutter_test.dart';
import 'package:opentier/protocol.dart';

void main() {
  test('command formatting', () {
    expect(MyTierProtocol.lock('1234'), 'AT+BKSCT=1234,1\$\r\n');
    expect(MyTierProtocol.unlock('1234'), 'AT+BKSCT=1234,0\$\r\n');
    expect(MyTierProtocol.getStatus('1234'), 'AT+BKINF=1234,0\$\r\n');
  });

  test('ACK lock/unlock', () {
    expect(MyTierProtocol.parseStatus('+ACK:BKSCT,0')!.isLocked, false);
    expect(MyTierProtocol.parseStatus('+ACK:BKSCT,1')!.isLocked, true);
  });

  test('5-field status frame: lockStatus at index 4', () {
    // +ACK:BKINF,<mileage>,<x>,<battery>,<lock>$
    final s = MyTierProtocol.parseStatus('+ACK:BKINF,123.4,0,92,0\$\r\n')!;
    expect(s.batteryPercentage, 92);
    expect(s.mileage, 123.4);
    expect(s.isLocked, true); // faithful to Kotlin: 5-field lock=="0" => isLocked true
    expect(s.estimatedRange, closeTo(92 * 0.35, 0.001));
  });

  test('4-field frame: lockStatus at index 0, low-battery multiplier', () {
    final s = MyTierProtocol.parseStatus('1,50.0,0,40\$\r\n')!;
    expect(s.batteryPercentage, 40);
    expect(s.isLocked, true); // "1" => locked
    expect(s.estimatedRange, closeTo(40 * 0.3, 0.001));
  });

  test('malformed frame returns null', () {
    expect(MyTierProtocol.parseStatus('garbage'), isNull);
  });
}
