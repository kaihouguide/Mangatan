#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$script_dir/.." && pwd)
generated_dir="$repo_dir/ios/EmbeddedMihon/runtime"
framework_dir="$repo_dir/ios/Frameworks/OpenJDK.xcframework"
lazy_framework_dir="$repo_dir/ios/Frameworks/OpenJDKRuntime.framework"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/mangatan-embedded-mihon.XXXXXX")
trap 'find "$work_dir" -depth -delete' EXIT

# Keep the current Mihon/TachiyomiX bytecode and media-proxy repairs while
# avoiding jdk.zipfs, which is intentionally absent from the small embedded
# iOS JRE.
server_commit="26cb31e9cc56f4e7aef2931eeba042c9858a8ba4"
server_jar_url="https://github.com/1Selxo/M-Extension-Server/releases/download/ios-runtime-v15/MExtensionServer-ios.jar"
server_jar_sha256="fa91f953972b0d40251c9b7cf19a69a6749dcc7fa6f30d149188efafeffd9142"
openjdk_framework_url="https://github.com/1Selxo/Mangatan/releases/download/embedded-openjdk-ios13-v16/OpenJDK.xcframework.zip"
openjdk_framework_sha256="f21681caae40e508647e7f18c9082f27fa9aa67ee7f1376725eae528fa2d38cb"
openjdk_bundle_url="https://github.com/1Selxo/Mangatan/releases/download/embedded-openjdk-ios13-v16/java_bundle-device.zip"
openjdk_bundle_sha256="15369b9bb9dfdd400c18c56b30e2f6cf316b81d4e0bae5ddd6b1fe72355c4b0b"

if [[ -z "${JAVA_HOME:-}" || ! -x "$JAVA_HOME/bin/javac" ]]; then
  echo "JAVA_HOME must point to a JDK 21 or newer." >&2
  exit 1
fi

java_major=$("$JAVA_HOME/bin/java" -version 2>&1 |
  sed -n '1s/.*version "\([0-9][0-9]*\).*/\1/p')
if [[ -z "$java_major" || "$java_major" -lt 21 ]]; then
  echo "JDK 21 or newer is required; found ${java_major:-unknown}." >&2
  exit 1
fi

download_and_verify() {
  local url=$1
  local sha256=$2
  local destination=$3
  curl --fail --location --retry 3 --output "$destination" "$url"
  (
    cd "$(dirname "$destination")"
    printf '%s  %s\n' "$sha256" "$(basename "$destination")" |
      shasum -a 256 --check
  )
}

echo "Downloading pinned M-Extension-Server $server_commit"
server_jar="$work_dir/MExtensionServer-ios.jar"
if [[ -n "${MIHON_SERVER_JAR_FILE:-}" ]]; then
  expected_commit=$(tr -d '\r\n' < "$script_dir/mihon_server_commit.txt")
  if [[ "${MIHON_SERVER_COMMIT:-}" != "$expected_commit" ||
        ! "${MIHON_SERVER_JAR_SHA256:-}" =~ ^[a-fA-F0-9]{64}$ ]]; then
    echo "A source-built server requires its pinned commit and SHA-256." >&2
    exit 1
  fi
  server_commit="$MIHON_SERVER_COMMIT"
  server_jar_sha256="$MIHON_SERVER_JAR_SHA256"
  echo "Using verified source-built M-Extension-Server $server_commit"
  cp "$MIHON_SERVER_JAR_FILE" "$server_jar"
  printf '%s  %s\n' "$server_jar_sha256" "$server_jar" | shasum -a 256 --check
else
  download_and_verify "$server_jar_url" "$server_jar_sha256" "$server_jar"
fi
if "$JAVA_HOME/bin/jar" tf "$server_jar" |
  grep -Eq '^(ch/qos/logback|org/cef|dev/datlag/kcef)/'; then
  echo "The iOS server JAR contains excluded desktop runtime classes." >&2
  exit 1
fi
server_entries="$work_dir/server-entries.txt"
"$JAVA_HOME/bin/jar" tf "$server_jar" > "$server_entries"
for required_resource in r_styles.ini r_values.ini; do
  if ! grep -qx "$required_resource" "$server_entries"; then
    echo "The iOS server JAR is missing $required_resource." >&2
    exit 1
  fi
done
if ! "$JAVA_HOME/bin/javap" \
  -classpath "$server_jar" \
  -constants org.objectweb.asm.Opcodes |
  grep -q 'V27 = 71'; then
  echo "The iOS server JAR cannot read OpenJDK 27 class files." >&2
  exit 1
fi

echo "Downloading verified OpenJDK Mobile runtime"
download_and_verify \
  "$openjdk_framework_url" \
  "$openjdk_framework_sha256" \
  "$work_dir/OpenJDK.xcframework.zip"
download_and_verify \
  "$openjdk_bundle_url" \
  "$openjdk_bundle_sha256" \
  "$work_dir/java_bundle-device.zip"
unzip -q "$work_dir/OpenJDK.xcframework.zip" -d "$work_dir/framework"
unzip -q "$work_dir/java_bundle-device.zip" -d "$work_dir/java-bundle"
runtime_archive=$(find "$work_dir/framework/OpenJDK.xcframework" \
  -type f -name 'libdevice.a' -print -quit)
if [[ -z "$runtime_archive" ]]; then
  echo "The OpenJDK XCFramework does not contain libdevice.a." >&2
  exit 1
fi
runtime_objects="$work_dir/runtime-objects"
mkdir "$runtime_objects"
(
  cd "$runtime_objects"
  ar -x "$runtime_archive"
)
python3 "$repo_dir/tool/verify_macho_min_ios.py" \
  --maximum 13.0 "$runtime_objects"

echo "Building java.util.logging compatibility shim"
shim_source="$repo_dir/tool/ios_jul_shim"
shim_classes="$work_dir/logging-shim-classes"
mkdir -p "$shim_classes"
"$JAVA_HOME/bin/javac" \
  --patch-module "java.logging=$shim_source" \
  -d "$shim_classes" \
  "$shim_source/java/util/logging/Level.java" \
  "$shim_source/java/util/logging/Logger.java"
"$JAVA_HOME/bin/jar" \
  --create \
  --file "$work_dir/java-logging-shim.jar" \
  -C "$shim_classes" .

echo "Staging embedded iOS runtime"
find "$generated_dir" -depth -delete 2>/dev/null || true
find "$framework_dir" -depth -delete 2>/dev/null || true
find "$lazy_framework_dir" -depth -delete 2>/dev/null || true
mkdir -p "$generated_dir/lib/security"
mkdir -p "$(dirname "$framework_dir")"
cp -R "$work_dir/framework/OpenJDK.xcframework" "$framework_dir"
cp "$work_dir/java-bundle/java_bundle-device/lib/modules" \
  "$generated_dir/lib/modules"
cp "$work_dir/java-bundle/java_bundle-device/lib/tzdb.dat" \
  "$generated_dir/lib/tzdb.dat"
cp -R "$work_dir/java-bundle/java_bundle-device/lib/security/." \
  "$generated_dir/lib/security/"
cp -R "$work_dir/java-bundle/java_bundle-device/conf" \
  "$generated_dir/conf"
cp "$work_dir/java-bundle/java_bundle-device/release" \
  "$generated_dir/release"
cp "$server_jar" "$generated_dir/MExtensionServer.jar"
cp "$work_dir/java-logging-shim.jar" \
  "$generated_dir/java-logging-shim.jar"
cp "$repo_dir/ios/EmbeddedMihon/THIRD_PARTY_NOTICES.md" \
  "$generated_dir/THIRD_PARTY_NOTICES.md"

test -f "$framework_dir/Info.plist"
test -f "$generated_dir/lib/modules"
test -f "$generated_dir/lib/tzdb.dat"
test -f "$generated_dir/lib/security/public_suffix_list.dat"
test -f "$generated_dir/conf/security/java.security"
test -f "$generated_dir/MExtensionServer.jar"
if [[ "$(uname -s)" == Darwin ]]; then
  "$repo_dir/tool/build_lazy_openjdk_ios.sh"
  test -x "$lazy_framework_dir/OpenJDKRuntime"
fi
echo "Embedded Mihon iOS runtime is ready."
