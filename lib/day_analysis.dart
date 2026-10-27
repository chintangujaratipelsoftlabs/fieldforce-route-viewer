import 'dart:math' as math;

import 'firestore_api.dart';
import 'rail_route.dart';

/// Points within this distance of a place for at least [kStopMinDuration]
/// are a stop, not travel.
const double kStopRadius = 120;
const Duration kStopMinDuration = Duration(minutes: 5);

/// No point for longer than this: a gap ("No locations").
const Duration kGapMin = Duration(minutes: 10);

/// Consecutive points further apart than this (the app stores one every
/// ~20 m while moving): the route in between was not recorded.
const double kMissMeters = 100;

/// Faster than this between two points is a GPS jump, not driving
/// (expressways reach 160 km/h).
const double kJumpKmh = 250;

/// gap: no locations for a while; missed: points missing along the way.
enum ItemKind { stop, trip, gap, missed }

/// A stretch the phone did not record, drawn as a dotted line.
class GapLine {
  GapLine(this.from, this.to, this.noLocations, [RailNetwork? rail])
    : ride = _sameShift(from, to)
          ? rail?.routeGap(
              from.lat,
              from.lng,
              from.time.millisecondsSinceEpoch,
              to.lat,
              to.lng,
              to.time.millisecondsSinceEpoch,
            )
          : null {
    reason = ride != null ? _rideReason(ride!) : _reason(from, to, noLocations);
  }

  final Fix from;
  final Fix to;

  /// No GPS while riding a metro / train (underground): measured along the
  /// line, the same way the app counts it.
  final RailRoute? ride;

  /// True: nothing stored for over [kGapMin]. False: points missed on the way.
  final bool noLocations;

  /// Why the route was not recorded, inferred from the points either side
  /// (the phone's own status log is not uploaded).
  late final String reason;

  /// Straight line between the two points.
  double get meters => DayAnalysis.meters(from, to);

  /// Counted for this stretch: along the line for a ride.
  double get countedMeters => ride?.meters ?? meters;

  /// Drawn dotted: along the line for a ride, else straight.
  List<(double, double)> get path =>
      ride?.path ?? [(from.lat, from.lng), (to.lat, to.lng)];

  Duration get duration => to.time.difference(from.time);

  /// The agent really travelled across this stretch (counted as a straight
  /// line): points missed on the way, or a long gap within one shift that
  /// covers real distance (underground metro, tunnel, phone not sending)
  /// rather than GPS paused while standing still.
  bool get travelled {
    if (!noLocations || ride != null) return true;
    if (!_sameShift(from, to)) return false;
    final kmh = meters / duration.inSeconds.clamp(1, 1 << 30) * 3.6;
    return meters >= 300 && kmh >= 5;
  }

  static bool _sameShift(Fix a, Fix b) =>
      a.shiftId.isEmpty || b.shiftId.isEmpty || a.shiftId == b.shiftId;

  static String _rideReason(RailRoute r) =>
      'No GPS while riding (underground ${r.metro ? 'metro' : 'train'} / '
      'tunnel) — ${(r.meters / 1000).toStringAsFixed(2)} km counted along the '
      '${r.metro ? 'metro' : 'train'} line (straight line '
      '${(r.straight / 1000).toStringAsFixed(2)} km)';

  static String _reason(Fix a, Fix b, bool noLocations) {
    final d = DayAnalysis.meters(a, b);
    final dt = b.time.difference(a.time).inMilliseconds / 1000;
    final weak =
        a.accuracy > 30 ||
        b.accuracy > 30 ||
        (a.source.isNotEmpty && a.source != 'gps') ||
        (b.source.isNotEmpty && b.source != 'gps');
    if (a.shiftId.isNotEmpty &&
        b.shiftId.isNotEmpty &&
        a.shiftId != b.shiftId) {
      return 'Duty off between shifts';
    }
    final kmhAll = dt > 0 ? d / dt * 3.6 : 0;
    if (noLocations) {
      if (d < 150) return 'Standing still: GPS paused to save battery (normal)';
      if (d >= 300 && kmhAll >= 15) {
        return 'No GPS while travelling (underground metro / tunnel) — straight line counted';
      }
      if (weak) return 'Weak GPS signal (indoors / covered area)';
      return 'Phone stopped sending: Location off, app closed by the phone, or no signal';
    }
    if (weak) return 'Weak GPS: points dropped';
    // Builds before 26 Oct dropped fixes worse than 15 m while moving slowly
    // (phones with weak GPS such as vivo V2060).
    if (a.accuracy > 15 || b.accuracy > 15) {
      return 'Weak GPS (accuracy over 15 m): points dropped by the old app';
    }
    final kmh = dt > 0 ? d / dt * 3.6 : double.infinity;
    if (kmh > kJumpKmh) return 'GPS jump (impossible speed)';
    // Builds before 25 Oct dropped every fix above 130 km/h (expressways).
    if (kmh > 100 || b.speed * 3.6 > 100 || a.speed * 3.6 > 100) {
      return 'Fast driving: points dropped by the old app (130 km/h limit, fixed in new build)';
    }
    return 'Short GPS loss (flyover / tunnel / tall buildings)';
  }
}

/// One row of the day: a stop, a trip, or a gap without locations.
class DayItem {
  DayItem(
    this.kind,
    this.start,
    this.end, {
    this.meters = 0,
    this.points = 0,
    this.lat,
    this.lng,
    this.reason,
    this.travelled = false,
  });

  final ItemKind kind;
  final DateTime start;
  final DateTime end;
  final double meters;
  final int points;

  /// Stop centre.
  final double? lat;
  final double? lng;

  /// Gaps and missed stretches: why the route was not recorded.
  final String? reason;

  /// Gaps: the straight line across counts as travelled.
  final bool travelled;

  Duration get duration => end.difference(start);
}

class DayAnalysis {
  DayAnalysis(this.fixes, this.items, this.segments, this.gapLines,
      [this.estimates = const []]);

  final List<Fix> fixes;

  /// Underground position estimates (shown, never counted).
  final List<Estimate> estimates;
  final List<DayItem> items;

  /// Runs of fixes without a gap, drawn as solid lines.
  final List<List<Fix>> segments;

  /// Where the route was not recorded: drawn dotted.
  final List<GapLine> gapLines;

  List<DayItem> get stops =>
      items.where((i) => i.kind == ItemKind.stop).toList();

  /// Total travelled: every hop between stored points, including the
  /// straight line across missed stretches (the agent did cover at least
  /// that), but not across "No locations" gaps. The app stores confirmed
  /// positions only, so this matches the distance the phone counted.
  double get travelledMeters {
    var m = 0.0;
    for (final seg in segments) {
      for (var k = 1; k < seg.length; k++) {
        m += meters(seg[k - 1], seg[k]);
      }
    }
    for (final g in gapLines) {
      if (g.travelled) m += g.countedMeters;
    }
    return m;
  }

  int get missedCount => gapLines.where((g) => !g.noLocations).length;

  /// Time spent on trips (moving), not at stops.
  Duration get movingTime => items
      .where((i) => i.kind == ItemKind.trip)
      .fold(Duration.zero, (d, i) => d + i.duration);

  /// Part of the total across stretches without GPS (underground metro,
  /// tunnels, missed points): along the line for rides, else straight.
  double get noGpsMeters => gapLines
      .where((g) => g.travelled)
      .fold(0.0, (m, g) => m + g.countedMeters);

  /// Part of [noGpsMeters] measured along metro / train lines.
  double get railMeters =>
      gapLines.fold(0.0, (m, g) => m + (g.ride?.meters ?? 0));

  int get noLocationCount => gapLines.where((g) => g.noLocations).length;

  Duration get untracked => items
      .where((i) => i.kind == ItemKind.gap)
      .fold(Duration.zero, (d, i) => d + i.duration);

  int get mockCount => fixes.where((f) => f.mock).length;

  int get weakCount => fixes.where((f) => f.accuracy > 50).length;

  /// Hops between consecutive fixes faster than [kJumpKmh].
  int get impossibleHops {
    var n = 0;
    for (var i = 1; i < fixes.length; i++) {
      final dt =
          fixes[i].time.difference(fixes[i - 1].time).inMilliseconds / 1000;
      final d = meters(fixes[i - 1], fixes[i]);
      if (dt > 0 && d / dt * 3.6 > kJumpKmh && d > 50) n++;
    }
    return n;
  }

  /// [rail]: metro / train lines, to measure underground rides (null:
  /// straight lines).
  static DayAnalysis of(
    List<Fix> fixes, {
    RailNetwork? rail,
    List<Estimate> estimates = const [],
  }) {
    final segments = <List<Fix>>[];
    final gapLines = <GapLine>[];
    var run = <Fix>[];
    for (final f in fixes) {
      if (run.isNotEmpty) {
        final noLocations = f.time.difference(run.last.time) > kGapMin;
        final missed = meters(run.last, f) > kMissMeters;
        if (noLocations || missed) {
          gapLines.add(GapLine(run.last, f, noLocations, rail));
          segments.add(run);
          run = [];
        }
      }
      run.add(f);
    }
    if (run.isNotEmpty) segments.add(run);

    final items = <DayItem>[];
    for (var s = 0; s < segments.length; s++) {
      if (s > 0) {
        final g = gapLines[s - 1];
        items.add(
          DayItem(
            g.noLocations ? ItemKind.gap : ItemKind.missed,
            g.from.time,
            g.to.time,
            meters: g.countedMeters,
            reason: g.reason,
            travelled: g.travelled,
          ),
        );
      }
      items.addAll(_stopsAndTrips(segments[s]));
    }
    return DayAnalysis(fixes, items, segments, gapLines, estimates);
  }

  static List<DayItem> _stopsAndTrips(List<Fix> run) {
    final out = <DayItem>[];
    var i = 0;
    var tripStart = 0;
    while (i < run.length) {
      // Grow a cluster around run[i].
      var j = i;
      while (j + 1 < run.length && meters(run[i], run[j + 1]) <= kStopRadius) {
        j++;
      }
      if (run[j].time.difference(run[i].time) >= kStopMinDuration) {
        if (i > tripStart) out.add(_trip(run, tripStart, i));
        final pts = run.sublist(i, j + 1);
        out.add(
          DayItem(
            ItemKind.stop,
            run[i].time,
            run[j].time,
            points: pts.length,
            lat: pts.map((p) => p.lat).reduce((a, b) => a + b) / pts.length,
            lng: pts.map((p) => p.lng).reduce((a, b) => a + b) / pts.length,
          ),
        );
        tripStart = j;
        i = j + 1;
      } else {
        i++;
      }
    }
    if (run.length - 1 > tripStart) {
      out.add(_trip(run, tripStart, run.length - 1));
    }
    return out;
  }

  static DayItem _trip(List<Fix> run, int from, int to) {
    var m = 0.0;
    for (var k = from + 1; k <= to; k++) {
      m += meters(run[k - 1], run[k]);
    }
    return DayItem(
      ItemKind.trip,
      run[from].time,
      run[to].time,
      meters: m,
      points: to - from + 1,
    );
  }

  static double meters(Fix a, Fix b) {
    const r = 6371000.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(b.lat - a.lat);
    final dLng = rad(b.lng - a.lng);
    final h =
        math.pow(math.sin(dLat / 2), 2) +
        math.cos(rad(a.lat)) *
            math.cos(rad(b.lat)) *
            math.pow(math.sin(dLng / 2), 2);
    return 2 * r * math.asin(math.sqrt(h));
  }
}
