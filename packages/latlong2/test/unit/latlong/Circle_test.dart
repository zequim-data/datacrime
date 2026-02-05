//@TestOn("content-shell")
import 'package:test/test.dart';

import 'package:latlong2/latlong.dart';
// import 'package:logging/logging.dart';

// Browser
// import "package:console_log_handler/console_log_handler.dart";

// Commandline
// import "package:console_log_handler/print_log_handler.dart";

void main() {
  // final Logger _logger = new Logger("test.Circle");
  // configLogging();

  const base = LatLng(0.0, 0.0);

  const distance = Distance();

  final circle = Circle(base, 1000.0);

  const Distance distanceHaversine = DistanceHaversine();
  final circleHaversine = Circle(base, 1000.0, calculator: const Haversine());

  group('Circle with Vincenty', () {
    setUp(() {});

    test(
        '> isInside - distance from 0.0,0.0 to 1.0,0.0 is 110574 meter (based on Vincenty)',
        () {
      const circle = Circle(LatLng(0.0, 0.0), 110574.0);
      const newPos = LatLng(1.0, 0.0);

      // final double dist = new Distance().distance(circle.center,newPos);
      // print(dist);

      expect(circle.isPointInside(newPos), isTrue);

      const circle2 = Circle(LatLng(0.0, 0.0), 110573.0);
      expect(circle2.isPointInside(newPos), isFalse);
    }); // end of 'isInside - ' test

    test('> isInside, bearing 0', () {
      const num bearing = 0;
      for (var dist in <num>[100, 500, 999, 1000]) {
        expect(
            circle.isPointInside(distance.offset(base, dist, bearing)), isTrue);
      }
      expect(
          circle.isPointInside(distance.offset(base, 1001, bearing)), isFalse);
    }); // end of 'isInside, bearing 0' test

    test('> isInside, bearing 90', () {
      const num bearing = 90;
      for (var dist in <num>[100, 500, 999, 1000]) {
        expect(
            circle.isPointInside(distance.offset(base, dist, bearing)), isTrue);
      }
      expect(
          circle.isPointInside(distance.offset(base, 1001, bearing)), isFalse);
    }); // end of 'isInside, bearing 0' test

    test('> isInside, bearing -90', () {
      const num bearing = -90;
      for (var dist in <num>[100, 500, 999, 1000]) {
        expect(
            circle.isPointInside(distance.offset(base, dist, bearing)), isTrue);
      }
      expect(
          circle.isPointInside(distance.offset(base, 1001, bearing)), isFalse);
    }); // end of 'isInside, bearing 0' test

    test('> isInside, bearing 180', () {
      const num bearing = 180;
      for (var dist in <num>[100, 500, 999, 1000]) {
        expect(
            circle.isPointInside(distance.offset(base, dist, bearing)), isTrue);
      }
      expect(
          circle.isPointInside(distance.offset(base, 1001, bearing)), isFalse);
    }); // end of 'isInside, bearing 0' test

    test('> isInside, bearing -180', () {
      const num bearing = -180;
      for (var dist in <num>[100, 500, 999, 1000]) {
        expect(
            circle.isPointInside(distance.offset(base, dist, bearing)), isTrue);
      }
      expect(
          circle.isPointInside(distance.offset(base, 1001, bearing)), isFalse);
    }); // end of 'isInside, bearing 0' test
  });
  // End of 'Circle with Haversine' group

  group('Circle with Haversine', () {
    test('> isInside, bearing 0', () {
      const num bearing = 0;
      for (var dist in <num>[100, 500, 999, 1000]) {
        expect(
            circleHaversine
                .isPointInside(distanceHaversine.offset(base, dist, bearing)),
            isTrue);
      }

      for (var dist in <num>[1001, 1002, 1003, 1004, 1005, 1006, 1007]) {
        expect(
            circleHaversine
                .isPointInside(distanceHaversine.offset(base, dist, bearing)),
            isFalse);
      }
    }); // end of 'isInside, bearing 0' test

    test('> isInside, bearing 90', () {
      const num bearing = 90;
      for (var dist in <num>[100, 500, 999, 1000]) {
        expect(
            circleHaversine
                .isPointInside(distanceHaversine.offset(base, dist, bearing)),
            isTrue);
      }
      expect(
          circleHaversine
              .isPointInside(distanceHaversine.offset(base, 1001, bearing)),
          isFalse);
    }); // end of 'isInside, bearing 0' test

    test('> isInside, bearing -90', () {
      const num bearing = -90;
      for (var dist in <num>[100, 500, 999, 1000]) {
        expect(
            circleHaversine
                .isPointInside(distanceHaversine.offset(base, dist, bearing)),
            isTrue);
      }
      expect(
          circleHaversine
              .isPointInside(distanceHaversine.offset(base, 1001, bearing)),
          isFalse);
    }); // end of 'isInside, bearing 0' test

    test('> isInside, bearing 180', () {
      const num bearing = 180;
      for (var dist in <num>[100, 500, 999, 1000]) {
        expect(
            circleHaversine
                .isPointInside(distanceHaversine.offset(base, dist, bearing)),
            isTrue);
      }

      expect(
          circleHaversine
              .isPointInside(distanceHaversine.offset(base, 1001, bearing)),
          isFalse);
    }); // end of 'isInside, bearing 0' test

    test('> isInside, bearing -180', () {
      const num bearing = -180;
      for (var dist in <num>[100, 500, 999, 1000]) {
        expect(
            circleHaversine
                .isPointInside(distanceHaversine.offset(base, dist, bearing)),
            isTrue);
      }

      expect(
          circleHaversine
              .isPointInside(distanceHaversine.offset(base, 1001, bearing)),
          isFalse);
    }); // end of 'isInside, bearing 0' test
  }); // End of 'Circle with Vincenty' group
}

// - Helper --------------------------------------------------------------------------------------
