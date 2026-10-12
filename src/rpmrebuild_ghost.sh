#!/usr/bin/env bash
###############################################################################
#   rpmrebuild_ghost.sh 
#      it's a part of the rpmrebuild project
#
#    Copyright (C) 2002, 2003, 2013 by Valery Reznic
#    Bug reports to: valery_reznic@users.sourceforge.net
#      or          : eric.gerbier@tutanota.com
#    $Id$
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
###############################################################################

################################################################
# This script get from stanard input data in the following format:
# <file_type>   - type of the file (as first field from 'ls -l' output)
# <file_flags>  - rpm file's flag (as %{FILEFLAGS:fflag}) - may be empty string
# <file_perm>   - file's permission (as %{FILEMODES:octal})
# <file_user>   - file's user id
# <file_group>  - file's group id
# <file_verify> - file's verify flags (as %{FILEVERIFYFLAGS:octal})
# <file_lang>   - file's language     (as %{FILELANGS})
# <file_caps>   - file's capablities  (as %{FILECAPS})
# <file>        - file name
#
# And it should create all (non-exist) ghost files under buildroot
#
# this format is used in the 3 scripts : 
# rpmrebuild_files.sh rpmrebuild_ghost.sh rpmrebuild_buildroot.sh
################################################################

MY_LIB_DIR=$( dirname "$0" ) || ( echo "ERROR $0 dirname $0"; exit 1)
MY_BASENAME=$( basename "$0" )
source "$MY_LIB_DIR/rpmrebuild_lib.src"    || ( echo "ERROR $0 source $MY_LIB_DIR/rpmrebuild_lib.src" ; exit 1)

if [ $# -ne 1 ] || [ -z "$1" ]
then
	Critical "Usage: $0 <buildroot>"
fi

BuildRoot="$1"

while :; do
	IFS= read -r file_type
	[ -z "$file_type" ] && break
	IFS= read -r file_flags
	IFS= read -r file_perm
	IFS= read -r file_user
	IFS= read -r file_group
	IFS= read -r file_verify
	IFS= read -r file_lang
	IFS= read -r file_cap
	IFS= read -r file

	case "$file_flags" in
		*g*)
			# It's a ghost file, ok
		;; 
		
		*)
			# Something else, skip
			continue
		;;
	esac
	# Full file name
	File="$BuildRoot/$file"
	{ [ -e "$File" ] || [ -L "$File" ]; } && continue # File/directory already exist, do nothing

	case "$file_type" in
		d*)
			# Directory. Ghost directory ?
			Mkdir_p "$File" || Critical "$MY_BASENAME Mkdir_p $File"
		;;

		*)
			# Not directory
			#  Just in case dir for ghost file not exist create it
			DirName=${File%/*}
			Mkdir_p "$DirName" || Critical "$MY_BASENAME Mkdir_p $DirName"
			# Create file itself
			> "$File" || Critical "$MY_BASENAME create $File"
		;;
	esac || Critical "$MY_BASENAME esac"
done || Critical "$MY_BASENAME done"
exit 0
