#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
(cd frontend && npm ci && npm run build)
mkdir -p src/main/resources/META-INF/resources
cp -R frontend/dist/. src/main/resources/META-INF/resources/
./gradlew --console=plain test quarkusBuild
printf '\nRun: java -jar build/quarkus-app/quarkus-run.jar\n'
