# Semak QR

Android-only floating overlay that checks a payment screenshot against the Semak QR backend before a transfer is made.

## Run

```powershell
flutter pub get
flutter run --dart-define=BACKEND_URL=https://your-backend.example
```

The backend URL must not end with `/`; the app adds `/check-transaction`. For a
physical phone, use the backend's deployed HTTPS URL or an HTTPS tunnel URL;
`localhost` and `127.0.0.1` point to the phone itself and will not work.

## UI-only demo (no backend required)

Install on a physical Android phone with:

```powershell
flutter run --dart-define=DEMO_MODE=true
```

Grant the overlay permission, open any other app, then tap the green Semak QR bubble. Choose **Preview flagged result** to see the loading and high-risk-result cards without uploading an image or contacting a backend.

## Permissions

On first launch Semak QR asks for two Android permissions:

1. **Display over other apps** lets the small Semak QR bubble float above a banking app. If the request does not open Settings: go to **Settings > Apps > Special app access > Display over other apps > Semak QR**, then turn it on.
2. **Photos and videos** allows Android to notify the app when a screenshot is created and lets you select a screenshot through the manual fallback. If it does not appear: go to **Settings > Apps > Semak QR > Permissions > Photos and videos**, then allow it.

Some banking apps block screenshots with `FLAG_SECURE`; use **Upload screenshot** in the expanded bubble with a screen you control for the demo. The app never copies, caches, or persists screenshots, extracted recipient details, or verdicts: the selected image is sent as a multipart `screenshot` field, processed for that request, and discarded.

## API contract

`POST {BACKEND_URL}/check-transaction` with multipart field `screenshot`. The expected response uses `risk_level`, `reason`, `evidence`, `recipient_name`, `account_number`, and `amount` in snake_case.
