import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// flutter drive --driver=test_driver/integration_test.dart
/// --target=integration_test/native_rigged_model_probe_test.dart
/// Pass ACCESS_TOKEN through dart defines, never through report data.
Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 10),
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    final output = File(
      Platform.environment['MAPBOX_PROBE_REPORT_PATH'] ??
          'build/native_probe_report.json',
    );
    await output.parent.create(recursive: true);
    await output.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
    );
  },
);
