# =====================================================================
# 로또픽 push + 배포  (push.bat 이 실행)
#  1) 변경 확인 — 앱(flutter 폴더)이 바뀌었으면 빌드번호 +1 → APK + 웹 빌드
#  2) lottoPick → GitHub push
#  3) 웹앱·APK·다운로드 페이지·version.json → stockEye\app\web\lotto → GitHub push
#     → stockEye Actions(app-build)가 Vercel 에 배포
#        https://stockeye-pacific74.vercel.app/lotto/               웹 버전 (메인 화면)
#        https://stockeye-pacific74.vercel.app/lotto/download.html  앱 다운로드 안내
#        https://stockeye-pacific74.vercel.app/lotto/lotto.apk      APK
#     → 설치된 앱은 켤 때 version.json 을 보고 업데이트 안내
# =====================================================================
param([string]$Message = '')

$ErrorActionPreference = 'Stop'
# push.bat 이 UTF-8 로 읽어 실행하므로 $PSScriptRoot 대신 LOTTO_ROOT 사용
$Root     = if ($env:LOTTO_ROOT) { $env:LOTTO_ROOT.TrimEnd('\', '/') } else { $PSScriptRoot }
$StockEye = if ($env:LOTTO_STOCKEYE) { $env:LOTTO_STOCKEYE } else { 'D:\stockPrj\stockEye' }
$Dest     = Join-Path $StockEye 'app/web/lotto'
$Flutter  = Join-Path $Root 'flutter'
$Pubspec  = Join-Path $Flutter 'pubspec.yaml'
$Apk      = Join-Path $Flutter 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk'
$VerFile  = Join-Path $Dest 'version.json'
$WebBuild = Join-Path $Flutter 'build/web'
$Utf8     = New-Object System.Text.UTF8Encoding $false
if (-not $Message) { $Message = 'update ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') }

function Invoke-Native([string]$exe, [string[]]$argv) {
  & $exe @argv
  if ($LASTEXITCODE -ne 0) { throw "$exe $($argv -join ' ') 실패 (코드 $LASTEXITCODE)" }
}
function Get-GitOut([string[]]$argv) {
  $out = & git @argv
  if ($LASTEXITCODE -ne 0) { throw "git $($argv -join ' ') 실패" }
  return (($out | Out-String).Trim())
}
function Test-Staged([string[]]$pathspec) {
  & git diff --cached --quiet -- @pathspec
  return ($LASTEXITCODE -ne 0)
}

try {
  if (-not (Test-Path (Join-Path $StockEye '.git'))) { throw "stockEye 저장소를 찾을 수 없습니다: $StockEye" }

  # ------------------------------------------------------------ 0) 웹 플랫폼 (처음 한 번)
  if (-not (Test-Path (Join-Path $Flutter 'web/index.html'))) {
    Write-Host "`n===== 웹 버전 추가 (처음 한 번) =====" -ForegroundColor Cyan
    Set-Location $Flutter
    Invoke-Native flutter @('create', '--platforms', 'web', '--project-name', 'lottopick', '--org', 'com.pacific74', '.')
    Invoke-Native flutter @('pub', 'get')
    Invoke-Native dart @('run', 'flutter_launcher_icons')
    $idx = Join-Path $Flutter 'web/index.html'
    $h = [IO.File]::ReadAllText($idx)
    $h = [regex]::Replace($h, '<title>.*?</title>', '<title>로또픽</title>')
    $h = $h.Replace('content="lottopick"', 'content="로또픽"')
    [IO.File]::WriteAllText($idx, $h, $Utf8)
    $mf = Join-Path $Flutter 'web/manifest.json'
    if (Test-Path $mf) {
      $j = [IO.File]::ReadAllText($mf).Replace('"name": "lottopick"', '"name": "로또픽"').Replace('"short_name": "lottopick"', '"short_name": "로또픽"')
      [IO.File]::WriteAllText($mf, $j, $Utf8)
    }
  }

  # ------------------------------------------------------------ 1) 변경 확인 / 빌드
  Write-Host "`n===== [1/3] 변경 확인 =====" -ForegroundColor Cyan
  Set-Location $Root
  Invoke-Native git @('add', '-A')
  $staged = Get-GitOut @('diff', '--cached', '--name-only')
  if ($staged -split "`r?`n" | Where-Object { $_ -match '(^|/)\.env$' }) {
    & git reset -q
    throw '.env 파일이 올라가려 합니다. 중단합니다 (.gitignore 확인).'
  }

  $deployed = $null
  if (Test-Path $VerFile) {
    try { $deployed = [IO.File]::ReadAllText($VerFile) | ConvertFrom-Json } catch { $deployed = $null }
  }

  $tree = Get-GitOut @('write-tree', '--prefix=flutter/')
  $needBuild = (-not $deployed) -or ("$($deployed.tree)" -ne $tree) -or (-not (Test-Path (Join-Path $Dest 'lotto.apk')))

  if ($needBuild) {
    # 빌드번호 = max(pubspec 빌드번호, 배포된 빌드번호 + 1)
    $text = [IO.File]::ReadAllText($Pubspec)
    $m = [regex]::Match($text, '(?m)^version:[ \t]*(\d+\.\d+\.\d+)\+(\d+)[ \t]*(?=\r?$)')
    if (-not $m.Success) { throw 'pubspec.yaml 에서 "version: x.y.z+N" 줄을 찾을 수 없습니다' }
    $verName = $m.Groups[1].Value
    $build = [int]$m.Groups[2].Value
    if ($deployed -and $deployed.build) { $build = [Math]::Max($build, [int]$deployed.build + 1) }
    $text = $text.Substring(0, $m.Index) + "version: $verName+$build" + $text.Substring($m.Index + $m.Length)
    [IO.File]::WriteAllText($Pubspec, $text, $Utf8)
    Invoke-Native git @('add', 'flutter/pubspec.yaml')
    $tree = Get-GitOut @('write-tree', '--prefix=flutter/')

    Write-Host "앱이 바뀌었습니다 → v$verName ($build) 빌드 (몇 분 걸립니다)" -ForegroundColor Yellow
    Set-Location $Flutter
    Invoke-Native flutter @('build', 'apk', '--release', '--split-per-abi')
    if (-not (Test-Path $Apk)) { throw "APK 가 없습니다: $Apk" }
    Write-Host '웹 빌드 (/lotto/ 경로용)' -ForegroundColor Yellow
    Invoke-Native flutter @('build', 'web', '--release', '--base-href', '/lotto/')
    if (-not (Test-Path (Join-Path $WebBuild 'index.html'))) { throw "웹 빌드 결과가 없습니다: $WebBuild" }
    Set-Location $Root
  } else {
    Write-Host "앱 변경 없음 → 빌드 생략 (배포된 빌드 $($deployed.build) 유지)"
  }

  # ------------------------------------------------------------ 2) lottoPick push
  Write-Host "`n===== [2/3] lottoPick commit + push =====" -ForegroundColor Cyan
  if (Test-Staged @('.')) { Invoke-Native git @('commit', '-m', $Message) } else { Write-Host 'lottoPick 변경 없음' }
  Invoke-Native git @('push')

  # ------------------------------------------------------------ 3) stockEye 로 배포
  Write-Host "`n===== [3/3] stockEye /lotto/ 배포 =====" -ForegroundColor Cyan
  New-Item -ItemType Directory -Force -Path $Dest | Out-Null
  if ($needBuild) {
    # 웹 빌드 결과로 통째로 교체 (예전 파일 정리)
    Get-ChildItem -Path $Dest -Force | Remove-Item -Recurse -Force
    Copy-Item -Path (Join-Path $WebBuild '*') -Destination $Dest -Recurse -Force
    Copy-Item $Apk (Join-Path $Dest 'lotto.apk') -Force
    # version.json: Flutter 웹이 쓰는 값(app_name, build_number 등) + 앱 업데이트용 값
    $info = [ordered]@{}
    $fv = Join-Path $WebBuild 'version.json'
    if (Test-Path $fv) {
      ([IO.File]::ReadAllText($fv) | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $info[$_.Name] = $_.Value }
    }
    $info['version']      = $verName
    $info['build_number'] = "$build"
    $info['build']        = $build
    $info['time']         = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    $info['apk']          = 'lotto.apk'
    $info['tree']         = $tree
    [IO.File]::WriteAllText($VerFile, ($info | ConvertTo-Json -Compress), $Utf8)
    Write-Host ([IO.File]::ReadAllText($VerFile))
  }
  Copy-Item (Join-Path $Root 'web/lotto/download.html') (Join-Path $Dest 'download.html') -Force
  Copy-Item (Join-Path $Flutter 'assets/icon/icon.png') (Join-Path $Dest 'icon.png') -Force

  Set-Location $StockEye
  Invoke-Native git @('add', '--', 'app/web/lotto')
  if (Test-Staged @('app/web/lotto')) {
    Invoke-Native git @('commit', '-m', "lotto: $Message", '--', 'app/web/lotto')
    Invoke-Native git @('pull', '--rebase', '--autostash')
    Invoke-Native git @('push')
    Write-Host "`n약 10분 뒤 반영됩니다 (stockEye Actions → app-build):" -ForegroundColor Green
    Write-Host '  https://stockeye-pacific74.vercel.app/lotto/              (웹)'
    Write-Host '  https://stockeye-pacific74.vercel.app/lotto/download.html (앱 받기)'
  } else {
    Write-Host '/lotto/ 변경 없음 → 배포 생략'
  }

  Write-Host "`n[완료]" -ForegroundColor Green
  exit 0
}
catch {
  Write-Host "`n[오류] $($_.Exception.Message)" -ForegroundColor Red
  Write-Host '위 메시지를 확인하세요. 아무것도 배포되지 않았거나 중간에서 멈췄습니다.'
  exit 1
}
