/*
 * Copyright (c) 2016, Michael Mitterer (office@mikemitterer.at),
 * IT-Consulting and Development Limited.
 *
 * All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import 'package:test/test.dart';
import 'package:latlong2/latlong.dart';
// import 'package:logging/logging.dart';

// Browser
// import "package:console_log_handler/console_log_handler.dart";

// Commandline
// import "package:console_log_handler/print_log_handler.dart";

void main() {
  // final Logger _logger = new Logger("test.LatLng");
  // configLogging();

  group('A group of tests', () {
    setUp(() {});

    test('> Range', () {
      expect(() => const LatLng(-80.0, 0.0), returnsNormally);
      expect(() => const LatLng(-100.0, 0.0), throwsAssertionError);
      expect(() => const LatLng(80.0, 0.0), returnsNormally);
      expect(() => const LatLng(100.0, 0.0), throwsAssertionError);
      expect(() => const LatLng(0.0, -170.0), returnsNormally);
      expect(() => const LatLng(0.0, -190.0), throwsAssertionError);
      expect(() => const LatLng(0.0, 170.0), returnsNormally);
      expect(() => const LatLng(0.0, 190.0), throwsAssertionError);
    }); // end of 'Range' test

    test('> Rad', () {
      expect((const LatLng(-80.0, 0.0)).latitudeInRad, -1.3962634015954636);
      expect((const LatLng(90.0, 0.0)).latitudeInRad, 1.5707963267948966);
      expect((const LatLng(0.0, 80.0)).longitudeInRad, 1.3962634015954636);
      expect((const LatLng(0.0, 90.0)).longitudeInRad, 1.5707963267948966);
    }); // end of 'Rad' test

    test('> toString', () {
      expect((const LatLng(-80.0, 0.0)).toString(),
          'LatLng(latitude:-80.0, longitude:0.0)');
      expect((const LatLng(-80.123456, 0.0)).toString(),
          'LatLng(latitude:-80.123456, longitude:0.0)');
    }); // end of 'toString' test

    test('> toJson', () {
      expect((const LatLng(-80.0, 0.0)).toJson(), {
        'coordinates': [0.0, -80.0]
      });
      expect((const LatLng(0.0, 80.0)).toJson(), {
        'coordinates': [80.0, 0.0]
      });
    });

    test('> fromJson', () {
      expect(
          LatLng.fromJson({
            'coordinates': [0.0, -80.0]
          }),
          const LatLng(-80.0, 0.0));
      expect(
          LatLng.fromJson({
            'coordinates': [80.0, 0.0]
          }),
          const LatLng(0.0, 80.0));
    });

    test('> equal', () {
      expect(const LatLng(-80.0, 0.0), const LatLng(-80.0, 0.0));
      expect(const LatLng(-80.0, 0.0), isNot(const LatLng(-80.1, 0.0)));
      expect(const LatLng(-80.0, 0.0), isNot(const LatLng(0.0, 80.0)));
    }); // end of 'equal' test
  });
}

final Matcher throwsAssertionError = throwsA(isA<AssertionError>());
