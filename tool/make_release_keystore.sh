#!/bin/sh
#
# Creates the Android release keystore — OUTSIDE the repository, on purpose.
#
# Run it once, per machine. Then put four values into GitHub (see the printout at
# the end) and the release workflow signs for real.
#
# WHY THE KEYSTORE LIVES OUTSIDE THE REPO. A keystore committed once is
# published forever: it cannot be removed from a clone somebody already made, and
# the only remedy is a new application id — which uninstalls nothing, so every
# existing user would be told to install a different app. Keeping the file
# somewhere no `git add -A` can reach it is the cheap half of that problem; the
# `.gitignore` entries for `*.jks` and `android/key.properties` are the other
# half, and neither is sufficient alone.
#
# WHY THE PASSWORDS ARE GENERATED HERE. A keystore's passwords are protecting
# one thing: the ability to sign an update that existing installations will
# accept. A memorable password is a password that is reused; `openssl rand`
# costs nothing and this one is typed by a machine.
#
# Usage:
#   sh tool/make_release_keystore.sh              # create, if there is not one
#   sh tool/make_release_keystore.sh --force      # replace it (see the warning)
#
# ⚠️ REPLACING A KEYSTORE BREAKS UPGRADES. Android refuses to install an APK
# signed by a different key over an existing one (`INSTALL_FAILED_UPDATE_
# INCOMPATIBLE`), so every phone with the old build must uninstall first — which
# also deletes its saved machines and stored SSH credentials. `--force` prints
# that and asks for the word.
set -eu

# The application id is read out of the Gradle file below, so run from the
# project root whatever the caller's cwd was.
cd "$(dirname "$0")/.."

DIR="${HP_KEYSTORE_DIR:-$HOME/.config/herdr-pocket}"
STORE="$DIR/release-keystore.jks"
ALIAS="${HP_KEYSTORE_ALIAS:-herdr-pocket}"
NOTES="$DIR/SETUP.txt"

force=0
refresh=0
case "${1:-}" in
  --force) force=1 ;;
  --refresh) refresh=1 ;;
esac

command -v keytool >/dev/null 2>&1 || {
  echo "keytool is not on PATH — it ships with the JDK (mise's java install has it)" >&2
  exit 1
}

# ------------------------------------------------------------------ refresh --
#
# Rewrites SETUP.txt (and the base64, and the extracted certificate) from a
# keystore that already exists, WITHOUT touching the key. What that is for: the
# notes are the only copy of a random password, so losing them used to mean
# losing the key's usefulness — and the fingerprints are worth recomputing
# whenever the application id changes.
if [ "$refresh" -eq 1 ]; then
  [ -f "$STORE" ] || { echo "no keystore at $STORE to refresh" >&2; exit 1; }
  store_password="${HP_KEYSTORE_PASSWORD:-$(sed -n 's/^store password  //p' "$NOTES" 2>/dev/null | head -1)}"
  if [ -z "$store_password" ]; then
    echo "cannot read the store password: $NOTES is missing or has no" >&2
    echo "'store password' line. Supply it instead with:" >&2
    echo "  HP_KEYSTORE_PASSWORD=... sh $0 --refresh" >&2
    exit 1
  fi
  key_password="${HP_KEY_PASSWORD:-$store_password}"
  force=0
fi

if [ -f "$STORE" ] && [ "$force" -eq 0 ] && [ "$refresh" -eq 0 ]; then
  echo "a keystore already exists at $STORE"
  echo "  (--force replaces it, and every installed copy of the app will then"
  echo "   refuse to upgrade without an uninstall first; --refresh rewrites"
  echo "   only the notes beside it)"
  echo
  echo "its values, as read from $NOTES:"
  grep -E '^(ANDROID_KEY|keystore)' "$NOTES" 2>/dev/null || {
    echo "  $NOTES is missing; decrypt the values with:"
    echo "    keytool -list -v -keystore $STORE"
  }
  exit 0
fi

if [ "$force" -eq 1 ] && [ -f "$STORE" ]; then
  echo "This will REPLACE $STORE."
  echo
  echo "  Every phone that already has the app installed will refuse to upgrade"
  echo "  over it, and must uninstall first — which deletes its saved machines"
  echo "  and its stored SSH credentials."
  echo
  printf 'Type "replace" to continue: '
  read -r answer
  [ "$answer" = "replace" ] || { echo "nothing changed"; exit 1; }
fi

mkdir -p "$DIR"
chmod 700 "$DIR"

if [ "$refresh" -eq 0 ]; then

# REMOVED FIRST, and that is not belt-and-braces. `keytool -genkeypair` on an
# EXISTING keystore opens it with the password it was given — and the password
# just generated is not the old one, so it fails with "Keystore was tampered
# with, or password was incorrect" and `set -e` exits. Found by running
# --force against the key this script had made a minute earlier.
rm -f "$STORE"

store_password="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
key_password="$store_password"

# 36500 days is 100 years. The Play Store requires a validity that outlives the
# app's useful life, and a key that expires is a key that cannot sign updates —
# there is no renewal. 100 rather than the more usual 25 is a deliberate
# over-shoot: nothing in the build or the platform cares, and it puts the
# question beyond anyone's career.
#
# The -dname is the least important field in the file and the least changeable:
# a self-signed certificate's subject is never verified by anything, but every
# value in it is baked into the signing identity, so editing one later means a
# NEW key — and a new key cannot upgrade an installed app.
keytool -genkeypair \
  -keystore "$STORE" \
  -storetype PKCS12 \
  -alias "$ALIAS" \
  -keyalg RSA -keysize 4096 \
  -validity 36500 \
  -dname "CN=Maddax, OU=Maddax, O=Maddax, L=Guangzhou, ST=Guangdong, C=CN" \
  -storepass "$store_password" \
  -keypass "$key_password" \
  -noprompt >/dev/null

chmod 600 "$STORE"

fi  # end of: not a --refresh

# The base64 of the whole file is what goes into the GitHub secret: secrets
# cannot hold a file, and a keystore pasted as text would be mangled by any
# editor that touched it.
base64 < "$STORE" > "$DIR/release-keystore.jks.base64"
chmod 600 "$DIR/release-keystore.jks.base64"

# ---------------------------------------------------------------- identity --
#
# Everything a third party asks for when you register an app: the fingerprints
# (WeChat, 高德, 友盟 and Google all want at least one of them), the public key
# in the two shapes people ask for, and the application id it belongs to.
#
# DERIVED, NEVER TYPED. A fingerprint copied out of a terminal by hand is a
# fingerprint that will be wrong in one character, and the failure it causes —
# "the signature does not match" from somebody else's SDK — is a day of looking
# in the wrong place.
cert_pem="$DIR/cert.pem"
keytool -exportcert -rfc -keystore "$STORE" -alias "$ALIAS" \
  -storepass "$store_password" > "$cert_pem" 2>/dev/null
chmod 600 "$cert_pem"

fp_md5="$(openssl x509 -in "$cert_pem" -noout -fingerprint -md5 2>/dev/null | sed 's/.*=//')"
fp_sha1="$(openssl x509 -in "$cert_pem" -noout -fingerprint -sha1 2>/dev/null | sed 's/.*=//')"
fp_sha256="$(openssl x509 -in "$cert_pem" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//')"

# `openssl rsa` is deprecated in OpenSSL 3 but `openssl pkey` has no -modulus,
# and the modulus is exactly what people ask for.
openssl x509 -in "$cert_pem" -noout -pubkey -noout > "$DIR/public-key.pem" 2>/dev/null
chmod 600 "$DIR/public-key.pem"

key_bits="$(openssl pkey -pubin -in "$DIR/public-key.pem" -text -noout 2>/dev/null \
  | sed -n 's/^Public-Key: (\([0-9]*\) bit)/\1/p')"
pubkey_der_hex="$(openssl pkey -pubin -in "$DIR/public-key.pem" -outform DER 2>/dev/null \
  | xxd -p | tr -d '\n')"
# The modulus is the 4096-bit number itself — 512 BYTES, 1024 hex characters.
modulus_hex="$(openssl rsa -pubin -in "$DIR/public-key.pem" -modulus -noout 2>/dev/null \
  | sed 's/^Modulus=//')"

# Read, not asked for: an application id that disagrees with the build is worse
# than no application id in the notes at all.
app_id="$(sed -n 's/^[[:space:]]*applicationId = "\(.*\)"/\1/p' \
  android/app/build.gradle.kts 2>/dev/null | head -1)"
[ -n "$app_id" ] || app_id="(could not read android/app/build.gradle.kts)"

# A local record, because the passwords are random and this is the only copy.
# Kept beside the keystore, 0600, outside the repository.
umask 077
cat > "$NOTES" <<EOF
herdr-pocket release signing
generated $(date -u '+%Y-%m-%dT%H:%M:%SZ')
keytool alias       $ALIAS
x509 subject        CN=Maddax, OU=Maddax, O=Maddax, L=Guangzhou, ST=Guangdong, C=CN
validity            36500 days (100 years)
key                 RSA ${key_bits} bit (SHA384withRSA self-signed)

======================= identity of the app it signs =======================

application id      $app_id
                    (Apple side: dev.maddax.herdrPocket — bundle ids allow
                     hyphens and dislike underscores; Android ids are the
                     opposite way round, which is why the two differ)

=========================== what third parties ask for =====================

certificate MD5     $fp_md5
certificate SHA-1   $fp_sha1
certificate SHA-256 $fp_sha256

public key DER      $pubkey_der_hex
                    (SubjectPublicKeyInfo, hex — this is what "public key"
                     means when a service prints one back at you)

public key modulus  $modulus_hex
                    (the RSA number on its own: ${key_bits} bit = 512 bytes =
                     1024 hex characters)

public key PEM      $DIR/public-key.pem
certificate PEM     $cert_pem

============================= files in this folder =========================

keystore   $STORE
base64     $DIR/release-keystore.jks.base64
alias      $ALIAS
store password  $store_password
key password    $key_password

GitHub → the repository → Settings → Secrets and variables → Actions → New
repository secret, four times:

  ANDROID_KEYSTORE_BASE64     the contents of release-keystore.jks.base64
  ANDROID_KEYSTORE_PASSWORD   $store_password
  ANDROID_KEY_ALIAS           $ALIAS
  ANDROID_KEY_PASSWORD        $key_password

Losing this file does not lose the keystore, but it does lose the passwords —
and a keystore whose password is gone cannot sign anything. Back both up
somewhere that is not this machine and not this repository.

Local release builds read android/key.properties instead:

  storeFile=$STORE
  storePassword=$store_password
  keyAlias=$ALIAS
  keyPassword=$key_password
EOF
chmod 600 "$NOTES"

cat <<EOF

  keystore   $STORE
  alias      $ALIAS
  notes      $NOTES   (contains the passwords — back it up)

  github secrets to set:

    ANDROID_KEYSTORE_BASE64     < contents of $DIR/release-keystore.jks.base64
    ANDROID_KEYSTORE_PASSWORD   $store_password
    ANDROID_KEY_ALIAS           $ALIAS
    ANDROID_KEY_PASSWORD        $key_password

  the same values, for a local release build, go in android/key.properties —
  which is in .gitignore.

  certificate MD5    $fp_md5
  certificate SHA-1  $fp_sha1

  print the certificate, to confirm the key you are signing with:
    keytool -list -v -keystore $STORE -alias $ALIAS -storepass '$store_password'
EOF
