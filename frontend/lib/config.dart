/// Supply this at build time, for example:
/// flutter run --dart-define=BACKEND_URL=https://api.example.com
const backendUrl = String.fromEnvironment('BACKEND_URL', defaultValue: '');

/// Lets the mobile UI be tested before the team backend is available.
const demoMode = bool.fromEnvironment('DEMO_MODE', defaultValue: false);
