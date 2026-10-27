import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'config.dart';
import 'day_analysis.dart';
import 'firestore_api.dart';
import 'rail_route.dart';
import 'route_map.dart';

final _hm = DateFormat('HH:mm');
final _hms = DateFormat('HH:mm:ss');
final _day = DateFormat('EEE, d MMM yyyy');
final _dayHm = DateFormat('d MMM HH:mm');
final _dayHms = DateFormat('d MMM HH:mm:ss');

String _km(double m) =>
    m >= 1000 ? '${(m / 1000).toStringAsFixed(2)} km' : '${m.round()} m';

String _dur(Duration d) => d.inHours > 0
    ? '${d.inHours} h ${d.inMinutes % 60} min'
    : d.inMinutes > 0
    ? '${d.inMinutes} min'
    : '${d.inSeconds} s';

/// Developer route viewer: pick a user, a date and a time window; the stored
/// locations are drawn full screen with stops, trips and gaps.
class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key, required this.session, required this.onLogout});

  /// Admin: user dropdown and every user. An agent: only their own routes.
  final Session session;
  final VoidCallback onLogout;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  FirestoreApi get _api => widget.session.api;
  bool get _admin => widget.session.isAdmin;

  List<FieldUser> _users = const [];
  final Map<String, DateTime?> _lastSeen = {};
  FieldUser? _user;
  // From date + time → To date + time (default: today 00:00 → 23:59). The
  // window may cross midnight, e.g. 25 Oct 23:00 → 26 Oct 02:00.
  DateTime _fromDate = DateUtils.dateOnly(DateTime.now());
  TimeOfDay _fromTime = const TimeOfDay(hour: 0, minute: 0);
  DateTime _toDate = DateUtils.dateOnly(DateTime.now());
  TimeOfDay _toTime = const TimeOfDay(hour: 23, minute: 59);
  bool _detailed = false;

  DayAnalysis? _dayData;
  int _index = 0;
  int _fitTick = 0;

  /// Dotted stretch clicked on the map (or in Day activity): its reason.
  GapLine? _pinnedGap;
  bool _loading = false;
  String? _error;
  Timer? _player;

  @override
  void initState() {
    super.initState();
    if (_admin) {
      _loadUsers();
    } else {
      // An agent sees only their own day: no user selection.
      _user = widget.session.self;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadDay());
    }
  }

  @override
  void dispose() {
    _player?.cancel();
    super.dispose();
  }

  Future<void> _loadUsers() async {
    if (!_admin) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final users = await _api.users();
      setState(() => _users = users);
      for (final u in users) {
        _api
            .lastSeen(u.userId)
            .then((t) {
              if (mounted) setState(() => _lastSeen[u.userId] = t);
            })
            .catchError((Object _) {});
      }
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  DateTime get _start => DateTime(
    _fromDate.year,
    _fromDate.month,
    _fromDate.day,
    _fromTime.hour,
    _fromTime.minute,
  );
  DateTime get _end => DateTime(
    _toDate.year,
    _toDate.month,
    _toDate.day,
    _toTime.hour,
    _toTime.minute,
    59,
    999,
  );

  /// Times show the date too when the window covers more than one day.
  bool get _multiDay => !DateUtils.isSameDay(_fromDate, _toDate);
  String _t(DateTime t) => _multiDay ? _dayHm.format(t) : _hm.format(t);
  String _ts(DateTime t) => _multiDay ? _dayHms.format(t) : _hms.format(t);

  Future<void> _loadDay() async {
    final user = _user;
    if (user == null) return;
    if (!_end.isAfter(_start)) {
      setState(
        () => _error = 'The To date/time must be after the From date/time.',
      );
      return;
    }
    _stop();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fixes = await _api.locations(user.userId, _start, _end);
      final rail = await _railNetwork(fixes);
      final estimates = await _api
          .estimates(user.userId, _start, _end)
          .catchError((Object _) => <Estimate>[]);
      setState(() {
        _dayData = DayAnalysis.of(fixes, rail: rail, estimates: estimates);
        _pinnedGap = null;
        _index = 0;
        _fitTick++;
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _select(FieldUser? u) {
    if (!_admin) return;
    setState(() {
      _user = u;
      _dayData = null;
    });
    _loadDay();
  }

  Future<void> _pickDate(bool from) async {
    final d = await showDatePicker(
      context: context,
      initialDate: from ? _fromDate : _toDate,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (d == null) return;
    setState(() {
      if (from) {
        _fromDate = d;
        // Keep the window valid: To moves along when From passes it.
        if (_toDate.isBefore(d)) _toDate = d;
      } else {
        _toDate = d;
        if (_fromDate.isAfter(d)) _fromDate = d;
      }
    });
    _loadDay();
  }

  Future<void> _pickTime(bool from) async {
    final t = await showTimePicker(
      context: context,
      initialTime: from ? _fromTime : _toTime,
      builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (t == null) return;
    setState(() => from ? _fromTime = t : _toTime = t);
    _loadDay();
  }

  /// One whole day, 00:00 → 23:59.
  void _setDay(DateTime d) {
    _fromDate = _toDate = DateUtils.dateOnly(d);
    _fromTime = const TimeOfDay(hour: 0, minute: 0);
    _toTime = const TimeOfDay(hour: 23, minute: 59);
  }

  void _togglePlay() {
    if (_player != null) return _stop();
    final n = _dayData?.fixes.length ?? 0;
    if (n < 2) return;
    if (_index >= n - 1) _index = 0;
    _player = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (_index >= n - 1) return _stop();
      setState(() => _index++);
    });
    setState(() {});
  }

  void _stop() {
    _player?.cancel();
    _player = null;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final day = _dayData;
    final fixes = day?.fixes ?? const <Fix>[];
    final current = fixes.isEmpty
        ? null
        : fixes[_index.clamp(0, fixes.length - 1)];
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: RouteMap(
              day: day,
              detailed: _detailed,
              current: current,
              fitTick: _fitTick,
              onGapTap: (g) => setState(() => _pinnedGap = g),
            ),
          ),
          if (_pinnedGap != null)
            Positioned(
              left: 12,
              bottom: fixes.isEmpty ? 12 : 118,
              child: GapReasonCard(
                _pinnedGap!,
                onClose: () => setState(() => _pinnedGap = null),
              ),
            ),
          Positioned(left: 12, top: 12, right: 404, child: _header(day)),
          Positioned(
            right: 12,
            top: 12,
            bottom: fixes.isEmpty ? 12 : 112,
            width: 380,
            child: _user == null && _admin
                ? _usersPanel()
                : _activityPanel(day),
          ),
          if (fixes.isNotEmpty)
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: _playback(fixes, current!),
            ),
          if (_loading)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(minHeight: 3),
            ),
        ],
      ),
    );
  }

  Widget _panel({
    required Widget child,
    EdgeInsets padding = const EdgeInsets.all(14),
  }) => Material(
    color: const Color(0xF2161A1D),
    elevation: 6,
    borderRadius: BorderRadius.circular(12),
    child: Padding(padding: padding, child: child),
  );

  Widget _header(DayAnalysis? day) {
    final scheme = Theme.of(context).colorScheme;
    final warn = TextStyle(
      color: Colors.amber.shade300,
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
    );
    final bad = TextStyle(
      color: Colors.red.shade300,
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
    );
    final muted = TextStyle(color: Colors.grey.shade400, fontSize: 12.5);
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                'Timeline',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
              ),
              const Spacer(),
              Text(
                _admin
                    ? 'Signed in as admin (all users)'
                    : 'Signed in as @${widget.session.name}',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 11.5),
              ),
              const SizedBox(width: 6),
              TextButton.icon(
                onPressed: widget.onLogout,
                icon: const Icon(Icons.logout, size: 15),
                label: const Text('Logout'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                useGoogleMaps ? 'Google Maps' : 'OpenStreetMap (no Maps key)',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  _user == null ? 'Timeline' : 'Timeline — ${_user!.username}',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (day != null) _totalCard(day),
            ],
          ),
          if (day != null) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 10,
              runSpacing: 2,
              children: [
                Text('${day.fixes.length} points', style: muted),
                if (day.fixes.isNotEmpty)
                  Text(
                    '${_t(day.fixes.first.time)} – ${_t(day.fixes.last.time)}',
                    style: muted,
                  ),
                if (day.noLocationCount > 0)
                  Text(
                    '${day.noLocationCount} no-location gaps · ${_dur(day.untracked)} untracked',
                    style: warn,
                  ),
                if (day.missedCount > 0)
                  Text(
                    '${day.missedCount} missed stretches (dotted)',
                    style: warn,
                  ),
                if (day.impossibleHops > 0)
                  Text('⚠ ${day.impossibleHops} impossible hops', style: bad),
                if (day.mockCount > 0)
                  Text('⚠ ${day.mockCount} mock-GPS points', style: bad),
                if (day.weakCount > 0)
                  Text('${day.weakCount} weak fixes (>50 m)', style: warn),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_admin)
                SizedBox(
                  width: 260,
                  child: DropdownButtonFormField<FieldUser>(
                    initialValue: _user,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Username · User ID',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (final u in _users)
                        DropdownMenuItem(
                          value: u,
                          child: Text(u.label, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: _select,
                  ),
                ),
              _rangeEnd('From', _fromDate, _fromTime, true),
              const Icon(Icons.arrow_forward, size: 18),
              _rangeEnd('To', _toDate, _toTime, false),
              IconButton.filledTonal(
                tooltip: 'Reload',
                onPressed: _user == null && _admin ? _loadUsers : _loadDay,
                icon: const Icon(Icons.refresh),
              ),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('Simple')),
                  ButtonSegment(value: true, label: Text('Detailed')),
                ],
                selected: {_detailed},
                onSelectionChanged: (s) => setState(() => _detailed = s.first),
                style: ButtonStyle(
                  backgroundColor: WidgetStateProperty.resolveWith(
                    (st) => st.contains(WidgetState.selected)
                        ? scheme.primary
                        : null,
                  ),
                  foregroundColor: WidgetStateProperty.resolveWith(
                    (st) => st.contains(WidgetState.selected)
                        ? scheme.onPrimary
                        : null,
                  ),
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: TextStyle(color: Colors.red.shade300)),
          ],
        ],
      ),
    );
  }

  /// Total travelled in the selected From → To window: trips only (stops and
  /// GPS wander are not travel; gaps without points are shown separately).
  Widget _totalCard(DayAnalysis day) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.primary.withValues(alpha: .5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'TOTAL TRAVELLED',
            style: TextStyle(
              color: scheme.primary,
              fontSize: 10.5,
              letterSpacing: .8,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            '${(day.travelledMeters / 1000).toStringAsFixed(2)} km',
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              height: 1.15,
            ),
          ),
          Text(
            [
              '${_dur(day.movingTime)} moving',
              if (day.railMeters >= 50)
                'incl. ${_km(day.railMeters)} underground ride along the line (estimated)',
              if (day.noGpsMeters - day.railMeters >= 50)
                'incl. ${_km(day.noGpsMeters - day.railMeters)} without GPS (straight line)',
            ].join(' · '),
            style: TextStyle(color: Colors.grey.shade400, fontSize: 11.5),
          ),
        ],
      ),
    );
  }

  /// "From" / "To": a date button and a time button.
  Widget _rangeEnd(String label, DateTime date, TimeOfDay time, bool from) =>
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label ',
            style: TextStyle(color: Colors.grey.shade400, fontSize: 12.5),
          ),
          OutlinedButton.icon(
            onPressed: () => _pickDate(from),
            icon: const Icon(Icons.calendar_today, size: 16),
            label: Text(_day.format(date)),
          ),
          const SizedBox(width: 6),
          OutlinedButton.icon(
            onPressed: () => _pickTime(from),
            icon: const Icon(Icons.schedule, size: 16),
            label: Text(time.format24),
          ),
        ],
      );

  Widget _usersPanel() {
    final now = DateTime.now();
    return _panel(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                const Text(
                  'Field users',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  'click to open their day',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              children: [
                for (final u in _users)
                  Builder(
                    builder: (_) {
                      final seen = _lastSeen[u.userId];
                      final today =
                          seen != null && DateUtils.isSameDay(seen, now);
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          Icons.circle,
                          size: 12,
                          color: today
                              ? Colors.greenAccent.shade400
                              : Colors.grey.shade600,
                        ),
                        title: Text(
                          u.label,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          [
                            if (seen == null)
                              'never located'
                            else
                              'last seen ${DateFormat('d MMM HH:mm').format(seen)}',
                            if (u.device != null && u.device!.isNotEmpty)
                              u.device!,
                          ].join(' · '),
                          style: TextStyle(
                            color: Colors.grey.shade500,
                            fontSize: 12,
                          ),
                        ),
                        onTap: () {
                          if (seen != null) _setDay(seen);
                          _select(u);
                        },
                      );
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _activityPanel(DayAnalysis? day) {
    final items = day?.items ?? const <DayItem>[];
    final fixes = day?.fixes ?? const <Fix>[];
    return _panel(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
            child: Row(
              children: [
                const Text(
                  'Day activity',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  '${day?.stops.length ?? 0} stops',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
                if (_admin)
                  IconButton(
                    tooltip: 'All users',
                    onPressed: () => _select(null),
                    icon: const Icon(Icons.people_alt_outlined, size: 18),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              [
                'USER ID ${_user!.userId}',
                if (_user!.device != null) _user!.device!.toUpperCase(),
                if (_user!.email.isNotEmpty) _user!.email,
              ].join(' · '),
              style: TextStyle(
                color: Colors.grey.shade500,
                fontSize: 11.5,
                letterSpacing: .3,
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text(
                      _loading
                          ? 'Loading…'
                          : 'No locations in this time window.',
                      style: TextStyle(color: Colors.grey.shade500),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: items.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, indent: 16, endIndent: 16),
                    itemBuilder: (_, i) => _itemTile(items[i], fixes),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _itemTile(DayItem it, List<Fix> fixes) {
    final (chip, color, text) = switch (it.kind) {
      ItemKind.stop => (
        '📍 stop',
        Colors.tealAccent.shade400,
        '${_dur(it.duration)} · ${it.points} fixes within ${kStopRadius.round()} m, not counted as travel',
      ),
      ItemKind.trip => (
        '🚗 trip',
        Colors.greenAccent.shade400,
        '${_km(it.meters)} in ${_dur(it.duration)} · ${it.points} points',
      ),
      ItemKind.gap => (
        'No locations',
        Colors.redAccent.shade200,
        '${it.reason} — ${_dur(it.duration)} without a point, ${_km(it.meters)} (${it.travelled ? 'counted' : 'not counted'})',
      ),
      ItemKind.missed => (
        'Route missed',
        Colors.orange.shade300,
        '${it.reason} — ${_km(it.meters)} with no points in between, in ${_dur(it.duration)}',
      ),
    };
    return InkWell(
      onTap: () {
        final i = fixes.indexWhere((f) => !f.time.isBefore(it.start));
        setState(() {
          if (i >= 0) _index = i;
          // A gap row also shows its reason card.
          final gaps = _dayData?.gapLines ?? const <GapLine>[];
          final g = gaps.where((g) => g.from.time == it.start).firstOrNull;
          if (g != null) _pinnedGap = g;
        });
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: _multiDay ? 150 : 92,
              child: Text(
                '${_t(it.start)} – ${_t(it.end)}',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: .15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                chip,
                style: TextStyle(
                  color: color,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: TextStyle(color: Colors.grey.shade300, fontSize: 12.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _playback(List<Fix> fixes, Fix f) {
    final kmh = f.speed > 0
        ? '${(f.speed * 3.6).toStringAsFixed(0)} km/h'
        : '—';
    return _panel(
      padding: const EdgeInsets.fromLTRB(10, 6, 18, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: _togglePlay,
                icon: Icon(_player == null ? Icons.play_arrow : Icons.pause),
              ),
              SizedBox(
                width: _multiDay ? 120 : 70,
                child: Text(
                  _ts(f.time),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Expanded(
                child: Slider(
                  value: _index.clamp(0, fixes.length - 1).toDouble(),
                  max: (fixes.length - 1).toDouble().clamp(1, double.infinity),
                  onChanged: (v) {
                    _stop();
                    setState(() => _index = v.round());
                  },
                ),
              ),
              Text(
                '${_index + 1} / ${fixes.length}',
                style: TextStyle(color: Colors.grey.shade400),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${f.lat.toStringAsFixed(6)}, ${f.lng.toStringAsFixed(6)} · ±${f.accuracy.toStringAsFixed(0)} m'
                    ' · ${f.source.isEmpty ? '?' : f.source} · activity ${f.activity.isEmpty ? '?' : f.activity}'
                    ' · $kmh${f.shiftId.isEmpty ? '' : ' · ${f.shiftId}'}',
                    style: TextStyle(
                      color: Colors.grey.shade300,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                if (f.mock)
                  Text(
                    '⚠ MOCK',
                    style: TextStyle(
                      color: Colors.red.shade300,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

extension on TimeOfDay {
  String get format24 =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

/// Metro / train line tiles published next to the viewer (the same ones the
/// app downloads), loaded once each.
Future<Map<String, dynamic>?>? _railIndex;
final _railTiles = <String, Future<RailNetwork?>>{};

/// The lines around [fixes] (their tiles and the ones next to them),
/// anywhere in the world. Null without any: gaps stay straight lines.
Future<RailNetwork?> _railNetwork(List<Fix> fixes) async {
  _railIndex ??= () async {
    try {
      final r = await http.get(Uri.base.resolve('rail/tiles/index.json'));
      if (r.statusCode != 200) return null;
      return ((jsonDecode(r.body) as Map<String, dynamic>)['tiles'] as Map)
          .cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }();
  final index = await _railIndex;
  if (index == null) return null;
  final keys = <String>{
    for (final f in fixes)
      for (var dy = -1; dy <= 1; dy++)
        for (var dx = -1; dx <= 1; dx++)
          RailNetwork.tileOf(f.lat + dy, f.lng + dx),
  }.where(index.containsKey);
  final parts = <RailNetwork>[];
  for (final k in keys) {
    final net = await (_railTiles[k] ??= () async {
      try {
        final r = await http.get(Uri.base.resolve('rail/tiles/$k.json'));
        return r.statusCode == 200 ? RailNetwork.parse(r.body) : null;
      } catch (_) {
        return null;
      }
    }());
    if (net != null) parts.add(net);
  }
  return parts.isEmpty ? null : RailNetwork.merge(parts);
}
