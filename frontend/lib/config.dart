/// Supply this at build time, for example:
/// flutter run --dart-define=BACKEND_URL=https://api.example.com
/// This is deliberately not localhost: a physical phone needs a deployed or
/// tunneled HTTPS endpoint that it can reach.
const backendBaseUrl = String.fromEnvironment('BACKEND_URL', defaultValue: '');

/// Lets the mobile UI be tested before the team backend is available.
const demoMode = bool.fromEnvironment('DEMO_MODE', defaultValue: false);
