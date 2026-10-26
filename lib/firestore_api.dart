import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';

/// A field user: `users/{userId}` in the FieldForce Firestore.
class FieldUser {
  const FieldUser({
    required this.userId,
    required this.username,
    required this.email,
    this.lastLoginAt,
    this.device,
  });

  final String userId;
  final String username;
  final String email;
  final DateTime? lastLoginAt;
  final String? device;

  String get label => '$username · $userId';
}

/// One stored location point (`users/{id}/locations/{uuid}`).
class Fix {
  const Fix({
    required this.time,
    required this.lat,
    required this.lng,
    required this.accuracy,
    required this.speed,
    required this.source,
    required this.activity,
    required this.mock,
    required this.shiftId,
  });

  final DateTime time;
  final double lat;
  final double lng;
  final double accuracy;
  final double speed;
  final String source;
  final String activity;
  final bool mock;
  final String shiftId;
}

/// Who is signed in to the viewer.
class Session {
  const Session(this.api, {required this.isAdmin, this.self});

  final FirestoreApi api;

  /// Admin: every user (developer account). Otherwise only [self].
  final bool isAdmin;
  final FieldUser? self;

  String get name => isAdmin ? 'admin' : self!.username;

  /// Signs in. `admin` is the admin view (the admin Firebase account, its
  /// password checked by Firebase); any other login is a FieldForce agent
  /// (username or email + password) who can only read their own data
  /// (Firestore rules).
  static Future<Session> login(String login, String password) async {
    final name = login.trim();
    if (kFirebaseApiKey.isEmpty || kProjectId.isEmpty) {
      throw const ApiException(
        'Not configured: build with --dart-define-from-file=web_config.json',
      );
    }
    if (name.toLowerCase() == kAdminUsername) {
      final api = FirestoreApi(kAdminEmail, password);
      await api._signIn();
      return Session(api, isAdmin: true);
    }
    var email = name.toLowerCase();
    if (!email.contains('@')) {
      // Username -> email (usernames/{name} is readable before sign-in).
      final r = await http.get(
        Uri.parse(
          'https://firestore.googleapis.com/v1/projects/$kProjectId/databases/(default)/documents/usernames/$email',
        ),
      );
      if (r.statusCode != 200) {
        throw const ApiException('No account with this username.');
      }
      final mapped =
          FirestoreApi._fields(jsonDecode(r.body))['email'] as String?;
      if (mapped == null) {
        throw const ApiException('No account with this username.');
      }
      email = mapped;
    }
    final api = FirestoreApi(email, password);
    final uid = await api._signIn();
    final account = await api._send(
      'GET',
      '${api._base}/accounts/$uid',
    ) as Map<String, dynamic>;
    final userId = '${FirestoreApi._fields(account)['user_id']}';
    final self = FirestoreApi._user(
      await api._send('GET', '${api._base}/users/$userId'),
    );
    return Session(api, isAdmin: false, self: self);
  }
}

/// Firestore REST client, signed in as one account: the read-only developer
/// account (admin) or a field agent (own data only).
class FirestoreApi {
  FirestoreApi(this._email, this._password);

  final String _email;
  final String _password;
  String? _token;
  DateTime _tokenAt = DateTime.fromMillisecondsSinceEpoch(0);

  String get _base =>
      'https://firestore.googleapis.com/v1/projects/$kProjectId/databases/(default)/documents';

  Future<String> _auth() async {
    // ID tokens last an hour; refresh a little early.
    if (_token != null &&
        DateTime.now().difference(_tokenAt) < const Duration(minutes: 50)) {
      return _token!;
    }
    await _signIn();
    return _token!;
  }

  /// Signs in and returns the Firebase Auth uid.
  Future<String> _signIn() async {
    final r = await http.post(
      Uri.parse(
        'https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=$kFirebaseApiKey',
      ),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': _email,
        'password': _password,
        'returnSecureToken': true,
      }),
    );
    if (r.statusCode != 200) {
      final msg =
          (r.body.contains('INVALID_LOGIN_CREDENTIALS') ||
              r.body.contains('INVALID_PASSWORD') ||
              r.body.contains('EMAIL_NOT_FOUND'))
          ? 'Incorrect username or password.'
          : 'Sign-in failed (${r.statusCode}).';
      throw ApiException(msg);
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    _token = body['idToken'] as String;
    _tokenAt = DateTime.now();
    return body['localId'] as String;
  }

  Future<dynamic> _send(String method, String url, [Object? body]) async {
    final token = await _auth();
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
    final uri = Uri.parse(url);
    final r = method == 'GET'
        ? await http.get(uri, headers: headers)
        : await http.post(uri, headers: headers, body: jsonEncode(body));
    if (r.statusCode == 403) {
      throw const ApiException('Permission denied for this account.');
    }
    if (r.statusCode != 200) {
      throw ApiException('Firestore ${r.statusCode}: ${r.body}');
    }
    return jsonDecode(r.body);
  }

  /// Every field user, sorted by numeric id.
  Future<List<FieldUser>> users() async {
    final out = <FieldUser>[];
    String? page;
    do {
      final r = await _send(
        'GET',
        '$_base/users?pageSize=300${page == null ? '' : '&pageToken=$page'}',
      ) as Map<String, dynamic>;
      for (final d in (r['documents'] as List? ?? const [])) {
        out.add(_user(d));
      }
      page = r['nextPageToken'] as String?;
    } while (page != null);
    out.sort((a, b) => a.userId.compareTo(b.userId));
    return out;
  }

  /// Locations of [userId] between [from] and [to], oldest first.
  Future<List<Fix>> locations(String userId, DateTime from, DateTime to) async {
    final rows = await _send('POST', '$_base/users/$userId:runQuery', {
      'structuredQuery': {
        'from': [
          {'collectionId': 'locations'},
        ],
        'where': {
          'compositeFilter': {
            'op': 'AND',
            'filters': [
              _range('GREATER_THAN_OR_EQUAL', from),
              _range('LESS_THAN_OR_EQUAL', to),
            ],
          },
        },
        'orderBy': [
          {
            'field': {'fieldPath': 'timestamp'},
            'direction': 'ASCENDING',
          },
        ],
      },
    }) as List;
    final out = <Fix>[];
    for (final row in rows) {
      final doc = (row as Map<String, dynamic>)['document'];
      if (doc == null) continue;
      final f = _fields(doc);
      final t = f['timestamp'] as DateTime?;
      final lat = (f['latitude'] as num?)?.toDouble();
      final lng = (f['longitude'] as num?)?.toDouble();
      if (t == null || lat == null || lng == null) continue;
      out.add(
        Fix(
          time: t.toLocal(),
          lat: lat,
          lng: lng,
          accuracy: (f['accuracy'] as num?)?.toDouble() ?? 0,
          speed: (f['speed'] as num?)?.toDouble() ?? 0,
          source: (f['source'] ?? '').toString(),
          activity: (f['activity'] ?? '').toString(),
          mock: f['isMock'] == true,
          shiftId: (f['shiftId'] ?? '').toString(),
        ),
      );
    }
    return out;
  }

  /// Time of the user's most recent stored location, if any.
  Future<DateTime?> lastSeen(String userId) async {
    final rows = await _send('POST', '$_base/users/$userId:runQuery', {
      'structuredQuery': {
        'from': [
          {'collectionId': 'locations'},
        ],
        'orderBy': [
          {
            'field': {'fieldPath': 'timestamp'},
            'direction': 'DESCENDING',
          },
        ],
        'limit': 1,
      },
    }) as List;
    for (final row in rows) {
      final doc = (row as Map<String, dynamic>)['document'];
      if (doc != null) {
        return (_fields(doc)['timestamp'] as DateTime?)?.toLocal();
      }
    }
    return null;
  }

  static FieldUser _user(dynamic doc) {
    final f = _fields(doc);
    final id = ((doc as Map<String, dynamic>)['name'] as String)
        .split('/')
        .last;
    final dev = f['device'] as Map<String, dynamic>?;
    return FieldUser(
      userId: id,
      username: (f['username'] ?? id).toString(),
      email: (f['email'] ?? '').toString(),
      lastLoginAt: f['lastLoginAt'] as DateTime?,
      device: dev == null
          ? null
          : '${dev['brand'] ?? ''} ${dev['model'] ?? ''}'.trim(),
    );
  }

  static Map<String, dynamic> _range(String op, DateTime t) => {
    'fieldFilter': {
      'field': {'fieldPath': 'timestamp'},
      'op': op,
      'value': {'timestampValue': t.toUtc().toIso8601String()},
    },
  };

  static Map<String, dynamic> _fields(dynamic doc) {
    final raw =
        (doc as Map<String, dynamic>)['fields'] as Map<String, dynamic>? ?? {};
    return raw.map((k, v) => MapEntry(k, _value(v as Map<String, dynamic>)));
  }

  static Object? _value(Map<String, dynamic> v) {
    if (v.containsKey('stringValue')) return v['stringValue'];
    if (v.containsKey('integerValue')) {
      return int.parse(v['integerValue'] as String);
    }
    if (v.containsKey('doubleValue')) {
      return (v['doubleValue'] as num).toDouble();
    }
    if (v.containsKey('booleanValue')) return v['booleanValue'];
    if (v.containsKey('timestampValue')) {
      return DateTime.parse(v['timestampValue'] as String);
    }
    if (v.containsKey('mapValue')) {
      final m =
          (v['mapValue'] as Map<String, dynamic>)['fields']
              as Map<String, dynamic>? ??
          {};
      return m.map((k, x) => MapEntry(k, _value(x as Map<String, dynamic>)));
    }
    return null;
  }
}

class ApiException implements Exception {
  const ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}
