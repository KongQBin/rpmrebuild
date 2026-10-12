#!/usr/bin/env bash
###############################################################################
#   rpmrebuild_files.sh 
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
# This script get from standard input data in the following format:
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
# Environment:
#   RPMREBUILD_PUG_FROM_FS - if value is 'yes', use permission, owner and group
#                            from filesystem, otherwise - from package query
#   RPMREBUILD_COMMENT_MISSING  - 'yes' - comment missing files,
#                                  otherwise - nothing
#   RPMREBUILD_WARNING - yes  -  warn, if filename has glob characters
#
# it is used in the 3 scripts : rpmrebuild_files.sh rpmrebuild_ghost.sh rpmrebuild_buildroot.sh
################################################################

MY_LIB_DIR=$( dirname "$0" ) || ( echo "ERROR $0 dirname $0"; exit 1)
MY_BASENAME=$( basename "$0" )
source "$MY_LIB_DIR/rpmrebuild_lib.src"    || ( echo "ERROR $0 source $MY_LIB_DIR/rpmrebuild_lib.src" ; exit 1)

FFLAGS="d c s m n g"
d_val="%doc "      # doc flag
c_val="%config"    # config flag
s_val=""           # spec. DO I need do something with it ?
m_val="missingok " # missignok
n_val="noreplace " # noreplace
g_val="%ghost "    # ghost

# Should be in the same order as in rpm.
VERIFY_FLAGS="md5 size link user group mtime mode rdev"

# Check if we need (and have) getcap
if [ "$RPMREBUILD_CAP_FROM_FS" = "yes" ]; then
	# Check if we have getcap program
	tst=$( type getcap 2>/dev/null )
	if [ -z "$tst" ]; then
		Warning "no getcap found, capability will not be taken from filesystem" 1>&2
		RPMREBUILD_CAP_FROM_FS="no"
	else
		: # OK, we have getcap
	fi
fi

if [ "$RPMREBUILD_PUG_FROM_FS" = "yes" ]; then
	echo "%defattr(-,-,-)"
fi

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

	# on fedora 33, centos 7, 8, the root directory "/" is owned by filesystem package
	# but for rpmrebuild, BUILDROOT is juste a symlink, not a directory (cf RpmBuild in rpmrebuild.sh)
	# so the build fails, the only simple way is to skip the root directory
	[ "$file" = "/" ] && continue

	miss_str=""
	if [ "$RPMREBUILD_COMMENT_MISSING" = "yes" ] && [ -z "$RPMREBUILD_package_flag" ]; then
		if [ -e "$file" ]; then
			miss_str=""
		else 
			miss_str='# MISSING: '
		fi
	fi

	# language handling
	[ "$file_lang" = "(none)" ] && file_lang=""
	if [ -z "$file_lang" ]; then
		lang_str=""
	else
		lang_str="%lang($file_lang) "
		if [ -n "$RPMREBUILD_package_flag" ] || [ -e "$file" ]; then
			miss_str=""
		else 
                    if [ ! -h "$file" ]; then
			miss_str='# MISSING: '
                    fi
		fi
	fi
   
	# %dir handling
	case "$file_type" in
		d*)
			dir_str="%dir "
		;;

		*)
			dir_str=""
		;;
	esac

	# %fflags handling
	if [ -z "$file_flags" ]; then
		fflags_str=""
	else
		for flag in $FFLAGS; do
			if [ -z "${file_flags##*${flag}*}" ]; then
				eval ${flag}_str="\$${flag}_val"
			else
				eval ${flag}_str=""
			fi
		done

		# Reset strings' values
		config_par=""; config_full=""

		config_par="${m_str}${n_str}"
		# Handle a rpm's bug described by Han Holl:
		# There are missignok or/and noreplace flag but no config flag
		# In this case I simple force using '%config' string
		[ -z "$config_par" ] || c_str=$c_val

		# Concatenate c_str with config_param. 
		# If config param non-empty strip it's last character
		config_full="${c_str}${config_par:+(${config_par%?})}" 

		# If config_full string non-empty add space
		config_full="${config_full:+${config_full} }"

		fflags_str="${d_str}${config_full}${g_str}"
	fi

	# %attr handling
	if [ "$RPMREBUILD_PUG_FROM_FS" = "yes" ]; then
		# get attribute from file system
		attr_str="%attr(-,-,-) "
	else
		# rpm 4.10.[12] doesn't support field width in the
		# query specifier.
		# Or at least I was not able to find out how use it.
		# So if before rpm 4.10.2 file_perm was always
		# 6 characters long, 2 - file type and 4 permissions
		# now it can be either 5 or 6 characters long
		# I don't want to use any external program 
		# sed, printf, whatever - for performance reason:
		# package can have man, many files.
		# So, I need to get last 4 characters using only
		# bash magic
		# Strip last 4 characters from the end of the string
		not_perm="${file_perm%????}"
		# Strip whatever characters we get from the start
		# of the string.
		# result will be 4 permissions characters
		file_perm="${file_perm#${not_perm}}"
		attr_str="%attr($file_perm, $file_user, $file_group) "
	fi

	# %caps handling
	if [ "$RPMREBUILD_CAP_FROM_FS" = "yes" ]; then
		# several output format are possible depending libcap version
		# /usr/bin/arping cap_net_raw=p
		# /usr/bin/ping = cap_net_admin,cap_net_raw+p
		file_cap=$(  getcap "$file" | rev | cut -f1 -d' ' | rev )
	else
		# get capability from rpm query
		[ "$file_cap" = "(none)" ] && file_cap=""
	fi
	if [ -n "$file_cap" ]; then
		caps_str="%caps($file_cap) "
	else
		caps_str=""
	fi

	# Verify handling
	verify_str=""
	verify_par=""
	non_verify_par=""
	Bit=1
	if [ "$file_verify" = "(none)" ]
	then
		# no file_verify
		verify_str=""
	else
		file_verify="0$file_verify" # make it octal for shell
		for verify_flag in $VERIFY_FLAGS; do
			if [ $(( file_verify & Bit )) -eq 0 ]; then
				non_verify_par="$non_verify_par$verify_flag "
			else
				verify_par="$verify_par$verify_flag "
			fi
			Bit=$(( Bit << 1 ))
		done

		# if bit after last verify bit is off I assume that
		# %verify( ...) was used
		# otherwise I assume %verify(not ...) was used.
		if [ $(( file_verify & Bit )) -eq 0 ]; then ## Use "verify_par"
			# If verify_par not empty, set verify_str to %verify($verify_par)
			# Strip last character from verify_par
			verify_str="${verify_par:+%verify(${verify_par%?}) }"
		else # Use "non_verify_par
			# If non_verify_par not empty, set verify_str to %verify(not $verify_par)
			# Strip last character from non_verify_par
			verify_str="${non_verify_par:+%verify(not ${non_verify_par%?}) }"
		fi
	fi

	# test for jokers in file : globing seems not to work
	# for performance reason, just if warning flag
	if [ "$RPMREBUILD_WARNING" = "yes" ]; then
		case "$file" in
			*[*?]*)
				cat <<-WARN_TXT 1>&2 || Critical "$MY_BASENAME cat"
				
				-------------------------------- WARNING ------------------------------------------
				file named $file contains globbing characters
				rpm building may not work
				-----------------------------------------------------------------------------------
				WARN_TXT
			;;
		esac
	fi

	file=${file//\\/\\\\}
	file=${file//\"/\\\"}

	# bash 2 syntaxe
	#[[ $file = *\** ]] && file=$(echo "$file"|sed 's/\*/\\*/')
	# bash 1 but with a fork (grep)
	#wild=$(echo $file | grep "\*")
	#[ -n "$wild" ] && file=$(echo "$file"|sed 's/\*/\\*/')
	# quick and portable
	case "$file" in
		*\**) file=${file//\*/\\*} ;;
		*) ;;
	esac
	printf '%s\n' "${miss_str}${lang_str}${dir_str}${fflags_str}${attr_str}${caps_str}${verify_str}\"${file}\""
done || Critical "$MY_BASENAME done"
exit 0
