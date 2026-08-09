#!/bin/sh
set -e
cd "$(dirname "$0")"

export PATH="$HOME/Library/pnpm:$HOME/.volta/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

if ! command -v pnpm >/dev/null 2>&1; then
	echo "warning: pnpm not found, leaving PatchworkWeb.bundle as-is"
	exit 0
fi

sources="src public vite index.html package.json pnpm-lock.yaml tsconfig.json vite.config.ts vite.config.embed.ts"
stamp=../PatchworkWeb.bundle/index.html

if [ -f "$stamp" ] && [ -z "$(find $sources -newer "$stamp" -print -quit)" ]; then
	exit 0
fi

pnpm install --prefer-offline
pnpm build
