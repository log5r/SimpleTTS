#!/bin/bash
# Standalone macOS installer. Copy this file to another Xcode project to reuse it.
set -euo pipefail

usage() {
  cat <<'HELP'
使い方: ./install.sh [オプション] [-- Xcodeのビルド設定...]

スクリプトと同じフォルダのXcodeプロジェクトをReleaseビルドし、
~/Applicationsへ配置します。アプリは起動しません。

  --project PATH        .xcodeprojを指定
  --workspace PATH      .xcworkspaceを指定（--schemeも指定してください）
  --scheme NAME         スキームを指定（既定: SimpleTTS）
  --app-target NAME     配置するアプリのターゲット（複数ある場合）
  --configuration NAME ビルド構成（既定: Release）
  --destination DIR     配置先フォルダ（既定: ~/Applications）
  --project-signing     Xcodeプロジェクトの署名設定を使用
  --app PATH            ビルド済みの.appを配置（ビルドを省略）
  -h, --help            この説明を表示

相対パスは呼び出し元の作業フォルダを基準にします。
既定の署名はローカル実行用のアドホック署名です。
HELP
}

fail() { printf 'エラー: %s\n' "$*" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print $2" "$1" 2>/dev/null; }
absolute_dir() { (cd -- "$1" && pwd -P); }
need_value() { [[ $# -ge 2 && -n "$2" ]] || fail "$1 に値が必要です。"; }

# Scheme used when --scheme is omitted.
default_scheme="SimpleTTS"

script_dir="$(absolute_dir "$(dirname -- "$0")")"
container=""; container_type=""; scheme=""; app_target=""
configuration=Release
destination="$HOME/Applications"
source_app=""; project_signing=false
extra_settings=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project|--workspace)
      need_value "$@"
      [[ -z "$container" ]] || fail '--projectと--workspaceはどちらか1つだけ指定してください。'
      container_type="${1#--}"; container="$2"; shift 2 ;;
    --scheme) need_value "$@"; scheme="$2"; shift 2 ;;
    --app-target) need_value "$@"; app_target="$2"; shift 2 ;;
    --configuration) need_value "$@"; configuration="$2"; shift 2 ;;
    --destination) need_value "$@"; destination="$2"; shift 2 ;;
    --app) need_value "$@"; source_app="$2"; shift 2 ;;
    --project-signing) project_signing=true; shift ;;
    --) shift; extra_settings=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) fail "不明な引数: $1（--helpで使い方を表示）" ;;
  esac
done
[[ "$(uname -s)" == Darwin ]] || fail 'macOS専用です。'

scratch="$(mktemp -d "${TMPDIR:-/tmp}/install-app.XXXXXX")"
stage=""; installed_app=""; committed=false
cleanup() {
  # A failed replacement must leave the previous app available.
  if [[ "$committed" == false && -n "$stage" && -d "$stage/previous.app" ]]; then
    if [[ ! -e "$installed_app" && ! -L "$installed_app" ]]; then
      if ! mv -- "$stage/previous.app" "$installed_app"; then
        printf '旧アプリは %s/previous.app に保管されています。\n' "$stage" >&2
        stage=""
      fi
    else
      printf '旧アプリは %s/previous.app に保管されています。\n' "$stage" >&2
      stage=""
    fi
  fi
  [[ -z "$stage" ]] || rm -rf -- "$stage"
  rm -rf -- "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -z "$source_app" ]]; then
  if [[ -z "$container" ]]; then
    shopt -s nullglob
    candidates=("$script_dir/"*.xcworkspace)
    if [[ ${#candidates[@]} -eq 0 ]]; then
      candidates=("$script_dir/"*.xcodeproj)
    fi
    [[ ${#candidates[@]} -gt 0 ]] || fail 'Xcodeプロジェクトがありません。--project、--workspace、または--appを指定してください。'
    if [[ ${#candidates[@]} -ne 1 ]]; then
      printf '候補: %s\n' "${candidates[@]}" >&2
      fail '--projectまたは--workspaceで選択してください。'
    fi
    container="${candidates[0]}"
    case "$container" in *.xcworkspace) container_type=workspace ;; *) container_type=project ;; esac
  fi
  container="$(absolute_dir "$container")"
  build_root="$(dirname -- "$container")/build/InstallDerivedData"
  xcode_args=("-$container_type" "$container")
  [[ -n "$scheme" ]] || scheme="$default_scheme"
  if [[ -z "$scheme" ]]; then
    xcodebuild "${xcode_args[@]}" -list -json > "$scratch/list.plist"
    /usr/bin/plutil -convert xml1 "$scratch/list.plist"
    schemes=(); index=0
    while value="$(plist "$scratch/list.plist" ":$container_type:schemes:$index")"; do
      schemes+=("$value"); index=$((index + 1))
    done
    if [[ ${#schemes[@]} -ne 1 ]]; then
      printf 'スキーム候補: %s\n' "${schemes[*]:-（なし）}" >&2
      fail '--schemeでビルドするスキームを指定してください。'
    fi
    scheme="${schemes[0]}"
  fi
  xcode_args+=(-scheme "$scheme" -configuration "$configuration"
    -destination 'generic/platform=macOS' -derivedDataPath "$build_root")
  if [[ "$project_signing" == false ]]; then
    xcode_args+=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
      PROVISIONING_PROFILE_SPECIFIER= CODE_SIGNING_ALLOWED=YES)
  fi
  # Only build-setting assignments are accepted; keep the platform and output path fixed.
  # macOS ships Bash 3.2, where expanding an empty array under nounset fails.
  if [[ ${#extra_settings[@]} -gt 0 ]]; then
    for setting in "${extra_settings[@]}"; do
      [[ "$setting" == *=* && "$setting" != -* ]] || fail "ビルド設定はKEY=VALUE形式で指定してください: $setting"
    done
    xcode_args+=("${extra_settings[@]}")
  fi
  xcodebuild "${xcode_args[@]}" -showBuildSettings -json > "$scratch/settings.plist"
  /usr/bin/plutil -convert xml1 "$scratch/settings.plist"
  apps=(); targets=(); index=0
  while target="$(plist "$scratch/settings.plist" ":$index:target")"; do
    prefix=":$index:buildSettings"
    if [[ "$(plist "$scratch/settings.plist" "$prefix:WRAPPER_EXTENSION" || true)" == app &&
          "$(plist "$scratch/settings.plist" "$prefix:PLATFORM_NAME" || true)" == macosx &&
          ( -z "$app_target" || "$target" == "$app_target" ) ]]; then
      product_dir="$(plist "$scratch/settings.plist" "$prefix:TARGET_BUILD_DIR")"
      product_name="$(plist "$scratch/settings.plist" "$prefix:FULL_PRODUCT_NAME")"
      apps+=("$product_dir/$product_name"); targets+=("$target")
    fi
    index=$((index + 1))
  done
  if [[ ${#apps[@]} -ne 1 ]]; then
    printf 'アプリターゲット候補: %s\n' "${targets[*]:-（なし）}" >&2
    fail 'macOSアプリを1つに特定できません。--schemeと--app-targetを確認してください。'
  fi
  source_app="${apps[0]}"
  printf 'ビルド: %s / %s\n' "$scheme" "$configuration"
  xcodebuild "${xcode_args[@]}" build
else
  [[ -z "$container$scheme$app_target" && ${#extra_settings[@]} -eq 0 && "$project_signing" == false && "$configuration" == Release ]] ||
    fail '--appとXcodeビルド用オプションは併用できません。'
fi

validate_app() {
  local app="$1" executable package_type
  [[ "$app" == *.app && -d "$app/Contents/MacOS" ]] || fail "macOSの.appではありません: $app"
  package_type="$(plist "$app/Contents/Info.plist" :CFBundlePackageType)" || fail "Info.plistを読めません: $app"
  [[ "$package_type" == APPL ]] || fail "アプリのバンドルではありません: $app"
  executable="$(plist "$app/Contents/Info.plist" :CFBundleExecutable)" || fail 'CFBundleExecutableがありません。'
  [[ -n "$executable" && "$executable" != */* && -x "$app/Contents/MacOS/$executable" ]] || fail 'アプリの実行ファイルがありません。'
}
source_app="$(absolute_dir "$source_app")"
validate_app "$source_app"
bundle_id="$(plist "$source_app/Contents/Info.plist" :CFBundleIdentifier)" || fail 'CFBundleIdentifierがありません。'
[[ -n "$bundle_id" ]] || fail 'Bundle IDが空です。'
mkdir -p -- "$destination"
destination="$(absolute_dir "$destination")"
installed_app="$destination/$(basename -- "$source_app")"
[[ "$source_app" != "$installed_app" ]] || fail 'コピー元と配置先が同じです。'
case "$destination/" in "$source_app/"*) fail 'アプリ内部には配置できません。' ;; esac

check_destination() {
  [[ ! -L "$installed_app" ]] || fail "配置先がシンボリックリンクです: $installed_app"
  if [[ -e "$installed_app" ]]; then
    existing_id="$(plist "$installed_app/Contents/Info.plist" :CFBundleIdentifier || true)"
    [[ "$existing_id" == "$bundle_id" ]] || fail "同名の別アプリが存在します: $installed_app"
  fi
  # Query NSWorkspace without launching or terminating any application.
  running="$(/usr/bin/osascript -l JavaScript - "$bundle_id" <<'JXA'
ObjC.import('AppKit');
function run(argv) {
  return $.NSRunningApplication.runningApplicationsWithBundleIdentifier(argv[0]).count > 0 ? 'yes' : 'no';
}
JXA
)"
  [[ "$running" == no ]] || fail '同じBundle IDのアプリが起動中です。終了してから再実行してください。'
}
check_destination
stage="$(mktemp -d "$destination/.install-app.XXXXXX")"
mkdir -- "$stage/new"
/usr/bin/ditto "$source_app" "$stage/new/$(basename -- "$source_app")"
validate_app "$stage/new/$(basename -- "$source_app")"
check_destination
if [[ -e "$installed_app" ]]; then
  mv -- "$installed_app" "$stage/previous.app"
fi
mv -- "$stage/new/$(basename -- "$source_app")" "$installed_app"
committed=true

register=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -x "$register" ]]; then
  "$register" -f "$installed_app" || printf '検索への登録に失敗しました。Finderから一度開いてください。\n' >&2
fi
printf '配置しました: %s\nSpotlight / Raycastからアプリ名で検索できます（反映に時間がかかる場合があります）。\n' "$installed_app"
