#!/usr/bin/env bash
# Build the addon zip for a version tag and upload it to CurseForge.
#
#   tools/release.sh v0.9.2            build and upload (needs CF_API_KEY)
#   tools/release.sh v0.9.2 --dry-run  build the zip and print what would be sent
#
# Run by .github/workflows/release.yml when a v* tag is pushed.
set -euo pipefail

tag="${1:?usage: tools/release.sh v1.2.3 [--dry-run]}"
dry="${2:-}"
version="${tag#v}"
project_id=1802813
site="https://wow.curseforge.com"
forever_type=88568          # CurseForge's game version type for WoW Forever
toc="Poor/Poor.toc"

cd "$(dirname "$0")/.."

toc_version="$(sed -n 's/^## Version: *//p' "$toc" | tr -d '\r')"
if [ "$toc_version" != "${version%%-*}" ]; then
	echo "Tag $tag does not match '## Version: $toc_version' in $toc" >&2
	exit 1
fi

# Interface 16001 -> game version 1.60.1
interface="$(sed -n 's/^## Interface: *//p' "$toc" | tr -d '\r' | cut -d, -f1)"
game_version="$((10#$interface / 10000)).$((10#$interface / 100 % 100)).$((10#$interface % 100))"

# 0.x versions and -beta tags are betas, -alpha tags are alphas, the rest are releases.
case "$version" in
	*-alpha*) release_type=alpha ;;
	*-beta*|0.*) release_type=beta ;;
	*) release_type=release ;;
esac

# The changelog is this version's section of CHANGELOG.md.
changelog="$(awk -v v="## ${version%%-*}" '$0 == v {on=1; next} /^## / {on=0} on' CHANGELOG.md | sed -e '/./,$!d')"
[ -n "$changelog" ] || changelog="Version $version"

mkdir -p dist
# WowUp picks a release's zip by the game it is for, and only takes one
# whose name ends in "-forever" for WoW Forever.
archive="dist/poor-$version-forever.zip"
rm -f "$archive"
zip -q -r "$archive" Poor
printf '%s\n' "$changelog" > "dist/notes-$version.md"   # the GitHub release uses this as its text
echo "Built $archive ($(unzip -l "$archive" | tail -1 | awk '{print $2}') files), game version $game_version, type $release_type"

if [ "$dry" = "--dry-run" ]; then
	printf 'Changelog:\n%s\n' "$changelog"
	exit 0
fi

: "${CF_API_KEY:?CF_API_KEY is not set. Add it as a repository secret.}"

versions="$(curl -sS --retry 3 -H "x-api-token: $CF_API_KEY" "$site/api/game/wow/versions")"
# The exact game version, else the newest one CurseForge knows for Forever.
version_id="$(jq -r --argjson t "$forever_type" --arg v "$game_version" \
	'(map(select(.gameVersionTypeID == $t and .name == $v)) | .[0].id) // (map(select(.gameVersionTypeID == $t)) | max_by(.id) | .id) // empty' <<<"$versions")"
if [ -z "$version_id" ]; then
	echo "Could not find a WoW Forever game version on CurseForge. Response began: ${versions:0:200}" >&2
	exit 1
fi

metadata="$(jq -n --arg name "$version" --arg type "$release_type" --arg log "$changelog" --argjson id "$version_id" \
	'{displayName: $name, gameVersions: [$id], releaseType: $type, changelog: $log, changelogType: "markdown"}')"

result="$(mktemp)"
code="$(curl -sS --retry 3 --retry-delay 10 -w '%{http_code}' -o "$result" \
	-H "x-api-token: $CF_API_KEY" -F "metadata=$metadata" -F "file=@$archive" \
	"$site/api/projects/$project_id/upload-file")"
if [ "$code" != "200" ]; then
	echo "CurseForge refused the upload (HTTP $code): $(cat "$result")" >&2
	exit 1
fi
echo "Uploaded to CurseForge: $(cat "$result")"
