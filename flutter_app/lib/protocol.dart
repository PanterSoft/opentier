/// Port of MyTierProtocol.kt — pure string logic, no platform deps.
class ScooterStatus {
  final bool isLocked;
  final int batteryPercentage;
  final double mileage;
  final double estimatedRange;

  const ScooterStatus({
    required this.isLocked,
    required this.batteryPercentage,
    this.mileage = 0,
    this.estimatedRange = 0,
  });

  ScooterStatus copyWith({int? batteryPercentage}) => ScooterStatus(
        isLocked: isLocked,
        batteryPercentage: batteryPercentage ?? this.batteryPercentage,
        mileage: mileage,
        estimatedRange: estimatedRange,
      );
}

class MyTierProtocol {
  static String lock(String password) => 'AT+BKSCT=$password,1\$\r\n';
  static String unlock(String password) => 'AT+BKSCT=$password,0\$\r\n';
  static String getStatus(String password) => 'AT+BKINF=$password,0\$\r\n';

  static double _range(int battery) => battery * (battery < 50 ? 0.3 : 0.35);

  static ScooterStatus? parseStatus(String response) {
    try {
      if (response.contains('+ACK:BKSCT,0')) {
        return const ScooterStatus(isLocked: false, batteryPercentage: 0);
      }
      if (response.contains('+ACK:BKSCT,1')) {
        return const ScooterStatus(isLocked: true, batteryPercentage: 0);
      }

      if (response.contains(',') && response.contains('\$')) {
        final clean = response
            .substring(response.contains(':') ? response.indexOf(':') + 1 : 0)
            .replaceAll('\$', '')
            .replaceAll('\r\n', '');
        final data = clean.split(',');

        if (data.length >= 5) {
          final mileage = double.tryParse(data[1].trim()) ?? 0;
          final battery = int.tryParse(data[3].trim()) ?? 0;
          final lockStatus = data[4].trim();
          return ScooterStatus(
            isLocked: lockStatus == '0',
            batteryPercentage: battery,
            mileage: mileage,
            estimatedRange: _range(battery),
          );
        } else if (data.length >= 4) {
          final lockStatus = data[0].trim();
          final mileage = double.tryParse(data[1].trim()) ?? 0;
          final battery = int.tryParse(data[3].trim()) ?? 0;
          return ScooterStatus(
            isLocked: lockStatus == '1' || lockStatus == 'L',
            batteryPercentage: battery,
            mileage: mileage,
            estimatedRange: _range(battery),
          );
        }
      }
    } catch (_) {
      // ponytail: swallow parse errors like the Kotlin original; malformed frame → null
    }
    return null;
  }
}
