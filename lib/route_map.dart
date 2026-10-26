import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart' as ll;

import 'config.dart';
import 'day_analysis.dart';
import 'firestore_api.dart';

final _hm = DateFormat('HH:mm');

const _route = Color(0xFF2F6FED);
const _gap = Color(0xFFE5484D); // no locations
const _missed = Color(0xFFF5A524); // points missed on the way
const _start = Color(0xFF30A46C);
const _end = Color(0xFFE5484D);
const _stop = Color(0xFF12A594);

/// Title shown at the middle of a dotted (not recorded) stretch.
String gapTitle(GapLine g) {
  final m = g.countedMeters;
  final d = m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${m.round()} m';
  final t = g.duration.inMinutes > 0
      ? '${g.duration.inMinutes} min'
      : '${g.duration.inSeconds} s';
  return g.noLocations ? 'No locations · $t · $d' : 'Route missed · $d in $t';
}

String stopLabel(DayItem s) {
  // A stop running past midnight shows its dates.
  final f = DateUtils.isSameDay(s.start, s.end)
      ? _hm
      : DateFormat('d MMM HH:mm');
  return '${f.format(s.start)}–${f.format(s.end)} · ${s.duration.inMinutes} min';
}

/// The day's route: Google Maps when a Maps JavaScript API key is configured,
/// otherwise OpenStreetMap.
class RouteMap extends StatelessWidget {
  const RouteMap({
    super.key,
    required this.day,
    required this.detailed,
    required this.current,
    required this.fitTick,
    required this.onGapTap,
  });

  final DayAnalysis? day;
  final bool detailed;

  /// Playback position.
  final Fix? current;

  /// Changes whenever the camera should fit the route again.
  final int fitTick;

  /// A dotted (not recorded) stretch was clicked: show its reason.
  final ValueChanged<GapLine> onGapTap;

  @override
  Widget build(BuildContext context) => useGoogleMaps
      ? _GoogleRouteMap(
          day: day,
          detailed: detailed,
          current: current,
          fitTick: fitTick,
          onGapTap: onGapTap,
        )
      : _OsmRouteMap(
          day: day,
          detailed: detailed,
          current: current,
          fitTick: fitTick,
          onGapTap: onGapTap,
        );
}

// --- Google Maps -------------------------------------------------------------

class _GoogleRouteMap extends StatefulWidget {
  const _GoogleRouteMap({
    required this.day,
    required this.detailed,
    required this.current,
    required this.fitTick,
    required this.onGapTap,
  });

  final DayAnalysis? day;
  final bool detailed;
  final Fix? current;
  final int fitTick;
  final ValueChanged<GapLine> onGapTap;

  @override
  State<_GoogleRouteMap> createState() => _GoogleRouteMapState();
}

class _GoogleRouteMapState extends State<_GoogleRouteMap> {
  gm.GoogleMapController? _map;

  static gm.LatLng _p(Fix f) => gm.LatLng(f.lat, f.lng);

  @override
  void didUpdateWidget(covariant _GoogleRouteMap old) {
    super.didUpdateWidget(old);
    if (old.fitTick != widget.fitTick) _fit();
  }

  void _fit() {
    final fixes = widget.day?.fixes ?? const <Fix>[];
    if (_map == null || fixes.isEmpty) return;
    var s = fixes.first.lat, n = s, w = fixes.first.lng, e = w;
    for (final f in fixes) {
      if (f.lat < s) s = f.lat;
      if (f.lat > n) n = f.lat;
      if (f.lng < w) w = f.lng;
      if (f.lng > e) e = f.lng;
    }
    _map!.animateCamera(
      gm.CameraUpdate.newLatLngBounds(
        gm.LatLngBounds(
          southwest: gm.LatLng(s, w),
          northeast: gm.LatLng(n + 1e-5, e + 1e-5),
        ),
        80,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final day = widget.day;
    final polylines = <gm.Polyline>{};
    final markers = <gm.Marker>{};
    final circles = <gm.Circle>{};
    if (day != null && day.fixes.isNotEmpty) {
      for (final (i, seg) in day.segments.indexed) {
        polylines.add(
          gm.Polyline(
            polylineId: gm.PolylineId('seg$i'),
            points: [for (final f in seg) _p(f)],
            color: _route,
            width: 5,
          ),
        );
      }
      for (final (i, g) in day.gapLines.indexed) {
        polylines.add(
          gm.Polyline(
            polylineId: gm.PolylineId('gap$i'),
            points: [for (final (a, b) in g.path) gm.LatLng(a, b)],
            color: g.noLocations ? _gap : _missed,
            width: 4,
            jointType: gm.JointType.round,
            patterns: [gm.PatternItem.dot, gm.PatternItem.gap(8)],
            // Google Maps has no hover: a click shows the reason.
            consumeTapEvents: true,
            onTap: () => widget.onGapTap(g),
          ),
        );
      }
      if (widget.detailed) {
        for (final (i, f) in day.fixes.indexed) {
          circles.add(
            gm.Circle(
              circleId: gm.CircleId('p$i'),
              center: _p(f),
              radius: 3,
              strokeWidth: 1,
              strokeColor: Colors.white,
              fillColor: f.mock ? Colors.orange : _route,
            ),
          );
        }
      }
      for (final (i, s) in day.stops.indexed) {
        markers.add(
          gm.Marker(
            markerId: gm.MarkerId('stop$i'),
            position: gm.LatLng(s.lat!, s.lng!),
            icon: gm.BitmapDescriptor.defaultMarkerWithHue(
              gm.BitmapDescriptor.hueCyan,
            ),
            infoWindow: gm.InfoWindow(
              title: 'Stop ${i + 1}',
              snippet: stopLabel(s),
            ),
          ),
        );
      }
      markers.add(
        gm.Marker(
          markerId: const gm.MarkerId('start'),
          position: _p(day.fixes.first),
          icon: gm.BitmapDescriptor.defaultMarkerWithHue(
            gm.BitmapDescriptor.hueGreen,
          ),
          infoWindow: gm.InfoWindow(
            title: 'Start ${_hm.format(day.fixes.first.time)}',
          ),
        ),
      );
      markers.add(
        gm.Marker(
          markerId: const gm.MarkerId('end'),
          position: _p(day.fixes.last),
          icon: gm.BitmapDescriptor.defaultMarkerWithHue(
            gm.BitmapDescriptor.hueRed,
          ),
          infoWindow: gm.InfoWindow(
            title: 'End ${_hm.format(day.fixes.last.time)}',
          ),
        ),
      );
      if (widget.current != null) {
        markers.add(
          gm.Marker(
            markerId: const gm.MarkerId('now'),
            position: _p(widget.current!),
            zIndexInt: 10,
            icon: gm.BitmapDescriptor.defaultMarkerWithHue(
              gm.BitmapDescriptor.hueViolet,
            ),
          ),
        );
      }
    }
    return gm.GoogleMap(
      initialCameraPosition: const gm.CameraPosition(
        target: gm.LatLng(22.5, 79),
        zoom: 5,
      ),
      polylines: polylines,
      markers: markers,
      circles: circles,
      zoomControlsEnabled: true,
      onMapCreated: (c) {
        _map = c;
        _fit();
      },
    );
  }
}

// --- OpenStreetMap -----------------------------------------------------------

class _OsmRouteMap extends StatefulWidget {
  const _OsmRouteMap({
    required this.day,
    required this.detailed,
    required this.current,
    required this.fitTick,
    required this.onGapTap,
  });

  final DayAnalysis? day;
  final bool detailed;
  final Fix? current;
  final int fitTick;
  final ValueChanged<GapLine> onGapTap;

  @override
  State<_OsmRouteMap> createState() => _OsmRouteMapState();
}

class _OsmRouteMapState extends State<_OsmRouteMap> {
  final _map = fm.MapController();
  bool _ready = false;

  // Dotted stretch under the mouse: its reason follows the cursor.
  final fm.LayerHitNotifier<GapLine> _gapHit = ValueNotifier(null);
  GapLine? _hover;
  Offset _hoverAt = Offset.zero;

  GapLine? get _hitGap {
    final values = _gapHit.value?.hitValues;
    return values == null || values.isEmpty ? null : values.first;
  }

  static ll.LatLng _p(Fix f) => ll.LatLng(f.lat, f.lng);

  @override
  void didUpdateWidget(covariant _OsmRouteMap old) {
    super.didUpdateWidget(old);
    if (old.fitTick != widget.fitTick) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
    }
  }

  void _fit() {
    final fixes = widget.day?.fixes ?? const <Fix>[];
    if (!_ready || fixes.isEmpty) return;
    final pts = [for (final f in fixes) _p(f)];
    if (pts.length == 1) {
      _map.move(pts.first, 17);
      return;
    }
    _map.fitCamera(
      fm.CameraFit.bounds(
        bounds: fm.LatLngBounds.fromPoints(pts),
        padding: const EdgeInsets.fromLTRB(60, 140, 420, 140),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final day = widget.day;
    final has = day != null && day.fixes.isNotEmpty;
    final map = fm.FlutterMap(
      mapController: _map,
      options: fm.MapOptions(
        initialCenter: const ll.LatLng(22.5, 79),
        initialZoom: 5,
        onMapReady: () {
          _ready = true;
          _fit();
        },
      ),
      children: [
        fm.TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.ikolvi.fieldforce_dev_viewer',
        ),
        if (has)
          fm.PolylineLayer(
            polylines: [
              for (final seg in day.segments)
                fm.Polyline(
                  points: [for (final f in seg) _p(f)],
                  color: _route,
                  strokeWidth: 5,
                ),
            ],
          ),
        // Not recorded: small dotted lines. Hover shows the reason, click pins it.
        if (has)
          MouseRegion(
            hitTestBehavior: HitTestBehavior.deferToChild,
            cursor: _hover == null
                ? MouseCursor.defer
                : SystemMouseCursors.click,
            onHover: (e) {
              final g = _hitGap;
              if (g != _hover || g != null) {
                setState(() {
                  _hover = g;
                  _hoverAt = e.localPosition;
                });
              }
            },
            onExit: (_) => setState(() => _hover = null),
            child: GestureDetector(
              onTap: () {
                final g = _hitGap;
                if (g != null) widget.onGapTap(g);
              },
              child: fm.PolylineLayer<GapLine>(
                hitNotifier: _gapHit,
                minimumHitbox: 14,
                polylines: [
                  for (final g in day.gapLines)
                    fm.Polyline(
                      points: [for (final (a, b) in g.path) ll.LatLng(a, b)],
                      color: g.noLocations ? _gap : _missed,
                      strokeWidth: 3.5,
                      pattern: const fm.StrokePattern.dotted(spacingFactor: 2),
                      hitValue: g,
                    ),
                ],
              ),
            ),
          ),
        if (has)
          fm.CircleLayer(
            circles: [
              for (final g in day.gapLines)
                fm.CircleMarker(
                  point: ll.LatLng(
                    g.path[g.path.length ~/ 2].$1,
                    g.path[g.path.length ~/ 2].$2,
                  ),
                  radius: 4,
                  color: g.noLocations ? _gap : _missed,
                  borderColor: Colors.white,
                  borderStrokeWidth: 1.5,
                ),
            ],
          ),
        if (has && widget.detailed)
          fm.CircleLayer(
            circles: [
              for (final f in day.fixes)
                fm.CircleMarker(
                  point: _p(f),
                  radius: 3.5,
                  color: f.mock ? Colors.orange : _route,
                  borderColor: Colors.white,
                  borderStrokeWidth: 1,
                ),
            ],
          ),
        if (has)
          fm.MarkerLayer(
            markers: [
              for (final (i, s) in day.stops.indexed)
                fm.Marker(
                  point: ll.LatLng(s.lat!, s.lng!),
                  width: 190,
                  height: 64,
                  child: _StopPin(index: i + 1, label: stopLabel(s)),
                ),
              fm.Marker(
                point: _p(day.fixes.first),
                width: 26,
                height: 26,
                child: const _Dot(_start, Icons.play_arrow),
              ),
              fm.Marker(
                point: _p(day.fixes.last),
                width: 26,
                height: 26,
                child: const _Dot(_end, Icons.flag),
              ),
              if (widget.current != null)
                fm.Marker(
                  point: _p(widget.current!),
                  width: 22,
                  height: 22,
                  child: const _Dot(Colors.deepPurpleAccent, null),
                ),
            ],
          ),
        const fm.SimpleAttributionWidget(
          source: Text('OpenStreetMap contributors'),
        ),
      ],
    );
    return Stack(
      children: [
        Positioned.fill(child: map),
        if (_hover != null)
          Positioned(
            left: _hoverAt.dx + 14,
            top: _hoverAt.dy + 14,
            child: IgnorePointer(child: GapReasonCard(_hover!)),
          ),
      ],
    );
  }
}

/// Why a dotted stretch was not recorded: the hover tooltip and the card a
/// click pins.
class GapReasonCard extends StatelessWidget {
  const GapReasonCard(this.gap, {super.key, this.onClose});

  final GapLine gap;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final color = gap.noLocations ? _gap : _missed;
    final times = '${_hm.format(gap.from.time)} → ${_hm.format(gap.to.time)}';
    return Material(
      color: const Color(0xF215181B),
      elevation: 4,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 300),
        padding: EdgeInsets.fromLTRB(10, 8, onClose == null ? 10 : 2, 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color, width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    gapTitle(gap),
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    gap.reason,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    times,
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 11),
                  ),
                ],
              ),
            ),
            if (onClose != null)
              IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                onPressed: onClose,
                icon: const Icon(Icons.close),
              ),
          ],
        ),
      ),
    );
  }
}

class _StopPin extends StatelessWidget {
  const _StopPin({required this.index, required this.label});

  final int index;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _stop,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: Text(
          '$index',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      const SizedBox(height: 3),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ],
  );
}

class _Dot extends StatelessWidget {
  const _Dot(this.color, this.icon);

  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 2),
      boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 4)],
    ),
    child: icon == null ? null : Icon(icon, size: 14, color: Colors.white),
  );
}
