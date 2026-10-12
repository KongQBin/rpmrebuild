#!/usr/bin/env bash
# E Gerbier 2022/09/30
# check shell syntaxe

type shellcheck > /dev/null 2>&1
if [ $? -ne 0 ]
then
	echo "shellcheck not found"
	exit 1
fi

set -o pipefail

# to avoid problem with translations
export SHELLCHECK=y

shellcheck -a -x rpmrebuild.sh | tee shellcheck.report
