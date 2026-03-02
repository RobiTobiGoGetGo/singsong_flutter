# SingSong Deployment Script
Write-Host "CLEANING AND BUILDING..." -ForegroundColor Yellow
flutter clean
flutter pub get
flutter build web --base-href "/singsong_flutter/" --no-wasm-dry-run

if ($LASTEXITCODE -ne 0) {
    Write-Host "BUILD FAILED!" -ForegroundColor Red
    exit
}

Write-Host "WIPING OLD WEB FILES..." -ForegroundColor Yellow
if (Test-Path "index.html") { Remove-Item -Force "index.html" }
if (Test-Path "main.dart.js") { Remove-Item -Force "main.dart.js" }
if (Test-Path "flutter.js") { Remove-Item -Force "flutter.js" }
if (Test-Path "manifest.json") { Remove-Item -Force "manifest.json" }
if (Test-Path "version.json") { Remove-Item -Force "version.json" }
if (Test-Path "favicon.png") { Remove-Item -Force "favicon.png" }
if (Test-Path "flutter_bootstrap.js") { Remove-Item -Force "flutter_bootstrap.js" }
if (Test-Path "flutter_service_worker.js") { Remove-Item -Force "flutter_service_worker.js" }
if (Test-Path "assets") { Remove-Item -Recurse -Force "assets" }
if (Test-Path "canvaskit") { Remove-Item -Recurse -Force "canvaskit" }
if (Test-Path "icons") { Remove-Item -Recurse -Force "icons" }

Write-Host "SYNCING NEW BUILD..." -ForegroundColor Yellow
Copy-Item -Path "build/web/*" -Destination "." -Recurse -Force

Write-Host "PUSHING TO GITHUB..." -ForegroundColor Yellow
git add .
git commit -m "Auto-Release v1.0.15+16"
git push origin main:gh-pages --force

Write-Host "SUCCESS! v1.0.15+16 is now on GitHub." -ForegroundColor Green
