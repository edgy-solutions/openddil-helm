{{/*
Data of the `-keycloak-theme` ConfigMap: the `openddil` login theme's
theme.properties and stylesheet, plus the script the Keycloak pod's
`theme` init container runs to assemble it. A named template so the
Deployment can checksum it: the theme is copied at pod start, so a
change here must roll the pod. See releasability.yaml.
*/}}
{{- define "openddil.keycloakThemeData" -}}
theme.properties: |
  parent=keycloak.v2

  # theme.properties keys like `styles` are NOT merged across the parent
  # chain -- a theme that sets the key at all must restate everything it
  # wants, including the parent's own sheet, or lose it. Keycloak
  # resolves each relative path by walking up the theme hierarchy, so
  # "css/styles.css" still finds keycloak.v2's own file even though this
  # theme carries no copy of it.
  styles=css/styles.css css/openddil.css
openddil.css: |
  /* Sign-in branding for the `openddil` login theme.

     The images come from login/resources/img/, which the `theme` init
     container fills at pod start: the OpenDDIL defaults baked into the
     frontend image, each one overridden by the same key in the branding
     ConfigMap when present. With neither (an older frontend image and no
     ConfigMap) both urls 404 and the header and background fall back to
     the parent theme's look, with the dark colour and card below.

     The header shows signin-logo.png only, so an overlay rebrands it with
     that one key. The wrapper holds only the realm name, one line of
     text, so `contain` would shrink the logo to that line and draw it
     over the name. Instead the logo gets its own band above the name,
     sized to the viewport: 22vh keeps a 1366x768 screen from scrolling,
     and the clamp keeps it legible on a phone and sane on a tall monitor. */
  #kc-header-wrapper {
    --openddil-logo-h: clamp(120px, 22vh, 240px);
    padding-top: calc(var(--openddil-logo-h) + 16px);
    background-repeat: no-repeat;
    background-position: center top;
    background-size: auto var(--openddil-logo-h);
    background-image: url("../img/signin-logo.png");
  }

  /* Full-page sign-in background, with a dark fallback colour so a
     tall/narrow source image still fills the viewport. CSS cannot make
     the fallback colour conditional on signin-background.jpg actually
     being present, so -- same as the form card below -- it applies
     unconditionally, including on an unbranded deployment. */
  html.login-pf body#keycloak-bg {
    background-color: #0f172a;
    background-image: url("../img/signin-background.jpg");
    background-repeat: no-repeat;
    background-position: center center;
    background-size: cover;
    background-attachment: fixed;
  }

  /* "Glass" form card: dark, translucent, blue-bordered. CSS has no way
     to apply this only when a background image loaded, so it is
     unconditional -- the fixed light-on-dark palette keeps it readable
     on the plain keycloak.v2 background too. */
  /* The panel the card sits on, which also carries the "Sign in to your
     account" title. keycloak.v2 paints it white in a light colour scheme
     and #26292d in a dark one; the title is light (below) in both, so a
     light-scheme browser showed white on white. Pin the dark value. */
  .pf-v5-c-login__main {
    background-color: #26292d;
  }

  .pf-v5-c-login__main-body {
    background: rgba(15, 23, 42, 0.55);
    backdrop-filter: blur(6px);
    border: 1px solid rgba(96, 165, 250, 0.45);
    border-radius: 8px;
    padding: 2rem;
    color: #f8fafc;
  }

  .pf-v5-c-login__main-body .pf-v5-c-form__label,
  .pf-v5-c-login__main-body label,
  .pf-v5-c-login__main-header .pf-v5-c-title {
    color: #f8fafc;
  }

  .pf-v5-c-login__main-body .pf-v5-c-button.pf-m-primary {
    background-color: #2563eb;
    border-color: #1d4ed8;
  }
assemble.sh: |
  # Builds /opt/keycloak/themes/openddil in the `theme` emptyDir. Runs in
  # the FRONTEND image, because that image is where the OpenDDIL defaults
  # live (/usr/share/nginx/html/brand/); the chart carries no images, which
  # keeps the release record well under its 1 MiB Secret limit.
  #
  # Per image: the branding ConfigMap's key wins, else the frontend default,
  # else nothing (an older frontend image without /brand/ must not
  # crash-loop the IdP; the page then falls back to the parent look).
  # The last line says what landed from where, so the log is the artifact.
  set -eu
  T=/theme/login
  mkdir -p "$T/resources/css" "$T/resources/img" "$T/messages"
  cp /theme-src/theme.properties "$T/theme.properties"
  cp /theme-src/openddil.css "$T/resources/css/openddil.css"
  landed=""
  for f in signin-logo.png signin-background.jpg; do
    if [ -f "/branding-src/$f" ]; then
      cp "/branding-src/$f" "$T/resources/img/$f"; landed="$landed $f=branding"
    elif [ -f "/usr/share/nginx/html/brand/$f" ]; then
      cp "/usr/share/nginx/html/brand/$f" "$T/resources/img/$f"; landed="$landed $f=default"
    else
      landed="$landed $f=none"
    fi
  done
  if [ -f /branding-src/keycloak-messages_en.properties ]; then
    cp /branding-src/keycloak-messages_en.properties "$T/messages/messages_en.properties"
    landed="$landed messages=branding"
  else
    landed="$landed messages=none"
  fi
  echo "keycloak theme:$landed"
{{- end }}
