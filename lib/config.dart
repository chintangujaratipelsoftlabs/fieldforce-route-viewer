/// Build-time settings from `--dart-define-from-file=web_config.json`.
/// Only public values: a Firebase web API key identifies the project, it is
/// not a secret (access is controlled by firestore.rules). Never put a
/// password here: everything in a web build can be read by anyone.
const kFirebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
const kProjectId = String.fromEnvironment('FIREBASE_PROJECT_ID');

/// Logging in as `admin` signs in to this Firebase account (the only one the
/// Firestore rules let read every user), with the password the admin types.
const kAdminUsername = 'admin';
const kAdminEmail = String.fromEnvironment(
  'ADMIN_EMAIL',
  defaultValue: 'dev.viewer@fieldforce.dev',
);

/// Google Maps JavaScript API key. Empty: OpenStreetMap is used instead.
const kMapsApiKey = String.fromEnvironment('MAPS_API_KEY');

bool get useGoogleMaps => kMapsApiKey.isNotEmpty;
