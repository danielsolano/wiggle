#!/bin/bash
# Cross-builds dist/Wiggle.exe from macOS or Linux. Requires the .NET SDK.
# On Windows use build.cmd instead, which needs nothing installed.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v dotnet >/dev/null 2>&1; then
  echo "dotnet was not found. Install the .NET SDK, or run build.cmd on Windows."
  exit 1
fi

rm -rf dist
dotnet build Wiggle.csproj -c Release -o dist --nologo -v quiet
ls -lh dist/Wiggle.exe
