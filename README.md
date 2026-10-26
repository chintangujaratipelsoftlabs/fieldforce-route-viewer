# FieldForce Route Viewer

Flutter web app to view the location routes recorded by the FieldForce field-agent app.

- **Field agents** sign in with their FieldForce username (or email) and password and see only their own routes.
- **Admin** signs in with username `admin` and the admin password, and can pick any user.

Pick a **From** and **To** date/time (default today 00:00–23:59) to see the route, total distance travelled,
stops, trips, and dotted lines where no location was recorded (hover or click a dotted line for the reason).

Access to the data is enforced by the Firebase security rules, not by this app: an agent's login can only
read that agent's own data.

## Run locally

```
flutter run -d chrome --dart-define-from-file=web_config.json
```

`web_config.json` holds only public values (the Firebase web API key and project id). Never put a password in
it: everything in a web build can be read by anyone.

## Publish (GitHub Pages)

```
flutter build web --release --base-href /fieldforce-route-viewer/ --dart-define-from-file=web_config.json
```

then push the contents of `build/web` to the `gh-pages` branch.
