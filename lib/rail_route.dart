import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Distance across a stretch without GPS, measured along the metro / rail
/// line instead of a straight line.
///
/// Underground (metro, tunnels) a phone gets no GPS at all for minutes, so
/// no filter (Kalman included) has points to work with: the trip only knows
/// where the agent went down and where they came up. The straight line
/// between the two undercounts a curving metro line by 5–35 %. When both
/// ends lie on a metro or train line and the timing fits a ride, the length
/// along the line is counted instead. No position is invented: both ends are
/// real GPS fixes, so nothing on the map can jump.
///
/// Shared file: lib/tracking/rail_route.dart in the app and
/// lib/rail_route.dart in dev_viewer (keep both copies the same).

/// Both ends must be this close to a line (GPS is lost at the station
/// entrance and found again at the exit).
const double kRailSnapMeters = 1000;

/// Changing lines at an interchange: tracks of different lines this close
/// are joined (OpenStreetMap draws each line separately).
const double kRailTransferMeters = 300;

/// Longest graph edge, so interchange search finds a vertex near any point.
const double _kMaxSegmentMeters = kRailTransferMeters / 2;

/// Only gaps at least this long and this far are rides; shorter losses are
/// flyovers and tall buildings, where the straight line is close enough.
const double kRailMinGapMeters = 800;
const int kRailMinGapMs = 2 * 60 * 1000;

/// Average speed across the gap (straight line): slower is walking near a
/// line, faster along the line than this is not a train.
const double kRailMinKmh = 12;
const double kRailMaxKmh = 120;

/// The line may be longer than the straight line by up to this factor
/// (or [kRailMaxDetourMeters]); a bigger detour means the agent did not ride
/// that line.
const double kRailMaxDetour = 1.6;
const double kRailMaxDetourMeters = 3000;

/// One gap measured along the lines.
class RailRoute {
  const RailRoute(this.meters, this.straight, this.path, this.metro);

  /// Walk to the line + along the line(s) + walk from the line.
  final double meters;
  final double straight;

  /// From the first fix to the last, along the line (lat, lng pairs).
  final List<(double, double)> path;

  /// Mostly metro / light rail / monorail (otherwise train).
  final bool metro;
}

/// The metro and train lines of a country (OpenStreetMap), as built by
/// tools/build_rail.py: `{"v":1,"built":"…","lines":[{"m":0|1,
/// "b":[minLat,minLng,maxLat,maxLng],"p":[lat,lng,dLat,dLng,…]}]}`, all in
/// 1e-5 degrees, m 0 = metro, 1 = train.
class RailNetwork {
  RailNetwork._(this.built, this._lines);

  final String built;
  final List<_Line> _lines;
  final Map<String, RailRoute?> _cache = {};

  int get lineCount => _lines.length;

  static RailNetwork parse(String source) {
    final d = jsonDecode(source) as Map<String, dynamic>;
    final lines = <_Line>[];
    for (final l in d['lines'] as List) {
      final m = l as Map<String, dynamic>;
      final b = (m['b'] as List).cast<int>();
      final p = (m['p'] as List).cast<int>();
      final n = p.length ~/ 2;
      final lat = Int32List(n), lng = Int32List(n);
      var a = 0, o = 0;
      for (var i = 0; i < n; i++) {
        a += p[2 * i];
        o += p[2 * i + 1];
        lat[i] = a;
        lng[i] = o;
      }
      lines.add(_Line(
        m['m'] == 0,
        b[0] / 1e5,
        b[1] / 1e5,
        b[2] / 1e5,
        b[3] / 1e5,
        lat,
        lng,
      ));
    }
    return RailNetwork._('${d['built'] ?? ''}', lines);
  }

  /// The ride across a GPS gap from (lat1, lng1) at [ms1] to (lat2, lng2) at
  /// [ms2], or null when it does not look like a metro / train ride (then
  /// the straight line stays).
  RailRoute? routeGap(
    double lat1,
    double lng1,
    int ms1,
    double lat2,
    double lng2,
    int ms2,
  ) {
    final dtMs = ms2 - ms1;
    final straight = railHaversine(lat1, lng1, lat2, lng2);
    if (straight < kRailMinGapMeters || dtMs < kRailMinGapMs) return null;
    if (straight / (dtMs / 1000) * 3.6 < kRailMinKmh) return null;
    final key = '$lat1,$lng1,$lat2,$lng2';
    if (_cache.containsKey(key)) return _ride(_cache[key], dtMs);
    final r = route(lat1, lng1, lat2, lng2);
    _cache[key] = r;
    return _ride(r, dtMs);
  }

  static RailRoute? _ride(RailRoute? r, int dtMs) {
    if (r == null) return null;
    if (r.meters / (dtMs / 1000) * 3.6 > kRailMaxKmh) return null;
    if (r.meters >
        math.max(r.straight * kRailMaxDetour, r.straight + kRailMaxDetourMeters)) {
      return null;
    }
    return r;
  }

  /// Shortest way between two points along the lines (walking to the
  /// nearest line at each end and between lines at interchanges).
  RailRoute? route(double lat1, double lng1, double lat2, double lng2) {
    final straight = railHaversine(lat1, lng1, lat2, lng2);
    final margin = math.max(3000.0, straight / 2) / 111000;
    final lo1 = math.min(lat1, lat2) - margin, hi1 = math.max(lat1, lat2) + margin;
    final mLng = margin / math.cos(lat1 * math.pi / 180);
    final lo2 = math.min(lng1, lng2) - mLng, hi2 = math.max(lng1, lng2) + mLng;

    // Graph of the lines near the gap; equal coordinates are one vertex.
    final ids = <int, int>{};
    final vLat = <double>[], vLng = <double>[], vMetro = <bool>[];
    final adj = <List<(int, double)>>[];
    final segs = <(int, int)>[];
    int vertex(double la, double ln, bool metro) {
      final k = (la * 1e5).round() * 100000000 + (ln * 1e5).round();
      return ids.putIfAbsent(k, () {
        vLat.add(la);
        vLng.add(ln);
        vMetro.add(metro);
        adj.add([]);
        return adj.length - 1;
      });
    }

    for (final l in _lines) {
      if (l.maxLat < lo1 || l.minLat > hi1 || l.maxLng < lo2 || l.minLng > hi2) {
        continue;
      }
      var prev = vertex(l.lat[0] / 1e5, l.lng[0] / 1e5, l.metro);
      for (var i = 1; i < l.lat.length; i++) {
        final la0 = l.lat[i - 1] / 1e5, ln0 = l.lng[i - 1] / 1e5;
        final la1 = l.lat[i] / 1e5, ln1 = l.lng[i] / 1e5;
        // Straight stretches are stored as one long segment: split them so
        // an interchange anywhere along them has a vertex nearby.
        final parts =
            (railHaversine(la0, ln0, la1, ln1) / _kMaxSegmentMeters).ceil();
        for (var k = 1; k <= parts; k++) {
          final v = vertex(la0 + (la1 - la0) * k / parts,
              ln0 + (ln1 - ln0) * k / parts, l.metro);
          if (v == prev) continue;
          final w = railHaversine(vLat[prev], vLng[prev], vLat[v], vLng[v]);
          adj[prev].add((v, w));
          adj[v].add((prev, w));
          segs.add((prev, v));
          prev = v;
        }
      }
    }
    if (segs.isEmpty) return null;
    final n = adj.length;

    // Connected pieces; join each vertex to the nearest vertex of every
    // other piece within [kRailTransferMeters] (interchanges).
    final comp = List.filled(n, -1);
    var c = 0;
    for (var v = 0; v < n; v++) {
      if (comp[v] >= 0) continue;
      final stack = [v];
      comp[v] = c;
      while (stack.isNotEmpty) {
        final x = stack.removeLast();
        for (final (y, _) in adj[x]) {
          if (comp[y] < 0) {
            comp[y] = c;
            stack.add(y);
          }
        }
      }
      c++;
    }
    if (c > 1) {
      const cell = kRailTransferMeters / 111000;
      final grid = <int, List<int>>{};
      int key(int gx, int gy) => gx * 1000000 + gy;
      for (var v = 0; v < n; v++) {
        grid
            .putIfAbsent(
                key((vLat[v] / cell).floor(), (vLng[v] / cell).floor()), () => [])
            .add(v);
      }
      for (var v = 0; v < n; v++) {
        final gx = (vLat[v] / cell).floor(), gy = (vLng[v] / cell).floor();
        final best = <int, (double, int)>{};
        for (var dx = -1; dx <= 1; dx++) {
          for (var dy = -1; dy <= 1; dy++) {
            for (final u in grid[key(gx + dx, gy + dy)] ?? const <int>[]) {
              if (comp[u] == comp[v] || u < v) continue;
              final w = railHaversine(vLat[v], vLng[v], vLat[u], vLng[u]);
              if (w <= kRailTransferMeters && w < (best[comp[u]]?.$1 ?? 1e18)) {
                best[comp[u]] = (w, u);
              }
            }
          }
        }
        for (final (w, u) in best.values) {
          adj[v].add((u, w));
          adj[u].add((v, w));
        }
      }
    }

    final a = _snap(lat1, lng1, segs, vLat, vLng);
    final b = _snap(lat2, lng2, segs, vLat, vLng);
    if (a.dist > kRailSnapMeters || b.dist > kRailSnapMeters) return null;

    // Dijkstra from the snapped start (vertex n) to the snapped end (n + 1).
    final start = n, end = n + 1;
    adj.add([]);
    adj.add([]);
    vLat
      ..add(a.lat)
      ..add(b.lat);
    vLng
      ..add(a.lng)
      ..add(b.lng);
    vMetro
      ..add(vMetro[a.i])
      ..add(vMetro[b.i]);
    for (final v in [a.i, a.j]) {
      adj[start].add((v, railHaversine(a.lat, a.lng, vLat[v], vLng[v])));
    }
    for (final v in [b.i, b.j]) {
      adj[v].add((end, railHaversine(b.lat, b.lng, vLat[v], vLng[v])));
    }
    if ({a.i, a.j}.containsAll([b.i, b.j])) {
      adj[start].add((end, railHaversine(a.lat, a.lng, b.lat, b.lng)));
    }
    final dist = List.filled(n + 2, double.infinity);
    final prev = List.filled(n + 2, -1);
    dist[start] = 0;
    final heap = _Heap()..push(0, start);
    while (heap.isNotEmpty) {
      final (d, x) = heap.pop();
      if (x == end) break;
      if (d > dist[x]) continue;
      for (final (y, w) in adj[x]) {
        if (d + w < dist[y]) {
          dist[y] = d + w;
          prev[y] = x;
          heap.push(d + w, y);
        }
      }
    }
    if (dist[end].isInfinite) return null;
    final path = <(double, double)>[(lat2, lng2)];
    var metroM = 0.0, trainM = 0.0;
    for (var v = end; v >= 0; v = prev[v]) {
      final p = prev[v];
      if (p >= 0) {
        final w = railHaversine(vLat[p], vLng[p], vLat[v], vLng[v]);
        if (vMetro[v]) {
          metroM += w;
        } else {
          trainM += w;
        }
      }
      path.add((vLat[v], vLng[v]));
    }
    path.add((lat1, lng1));
    return RailRoute(
      a.dist + dist[end] + b.dist,
      straight,
      path.reversed.toList(),
      metroM >= trainM,
    );
  }

  static _Snap _snap(double lat, double lng, List<(int, int)> segs,
      List<double> vLat, List<double> vLng) {
    final k = math.cos(lat * math.pi / 180);
    var best = _Snap(double.infinity, 0, 0, lat, lng);
    for (final (i, j) in segs) {
      final ax = (vLng[i] - lng) * k, ay = vLat[i] - lat;
      final bx = (vLng[j] - lng) * k, by = vLat[j] - lat;
      final dx = bx - ax, dy = by - ay;
      final len = dx * dx + dy * dy;
      final t = len == 0 ? 0.0 : (-(ax * dx + ay * dy) / len).clamp(0.0, 1.0);
      final pLat = vLat[i] + t * (vLat[j] - vLat[i]);
      final pLng = vLng[i] + t * (vLng[j] - vLng[i]);
      final d = railHaversine(lat, lng, pLat, pLng);
      if (d < best.dist) best = _Snap(d, i, j, pLat, pLng);
    }
    return best;
  }
}

class _Line {
  const _Line(this.metro, this.minLat, this.minLng, this.maxLat, this.maxLng,
      this.lat, this.lng);

  final bool metro;
  final double minLat, minLng, maxLat, maxLng;
  /// Points in 1e-5 degrees (compact: a country has ~1 million).
  final Int32List lat, lng;
}

/// Nearest point on segment (i, j).
class _Snap {
  const _Snap(this.dist, this.i, this.j, this.lat, this.lng);

  final double dist;
  final int i, j;
  final double lat, lng;
}

/// Binary min-heap of (distance, vertex).
class _Heap {
  final _d = <double>[];
  final _v = <int>[];

  bool get isNotEmpty => _d.isNotEmpty;

  void push(double d, int v) {
    _d.add(d);
    _v.add(v);
    var i = _d.length - 1;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (_d[p] <= _d[i]) break;
      _swap(i, p);
      i = p;
    }
  }

  (double, int) pop() {
    final top = (_d[0], _v[0]);
    final lastD = _d.removeLast(), lastV = _v.removeLast();
    if (_d.isNotEmpty) {
      _d[0] = lastD;
      _v[0] = lastV;
      var i = 0;
      while (true) {
        final l = 2 * i + 1, r = l + 1;
        var m = i;
        if (l < _d.length && _d[l] < _d[m]) m = l;
        if (r < _d.length && _d[r] < _d[m]) m = r;
        if (m == i) break;
        _swap(i, m);
        i = m;
      }
    }
    return top;
  }

  void _swap(int a, int b) {
    final d = _d[a], v = _v[a];
    _d[a] = _d[b];
    _v[a] = _v[b];
    _d[b] = d;
    _v[b] = v;
  }
}

/// Metres between two coordinates.
double railHaversine(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.sqrt(h));
}
