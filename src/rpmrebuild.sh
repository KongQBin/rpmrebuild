#!/usr/bin/env bash
###############################################################################
#   rpmrebuild.sh 
#
#    Copyright (C) 2002 by Eric Gerbier
#    Bug reports to: eric.gerbier@tutanota.com
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
# shellcheck disable=SC2181
#  Check exit code directly with e.g. if mycmd;, not indirectly with $?
# shellcheck disable=SC1090
#  ShellCheck can't follow non-constant source

# debug 
#set -x 
###############################################################################
function GetVersion
{
	if [ -f "$MY_LIB_DIR/Version" ]
	then
		VERSION=$( cat "$MY_LIB_DIR"/Version )
	else
		Warning "(GetVersion) $FileNotFound Version"
	fi
}
###############################################################################
# edit spec file
# use environment variable to choice the editor
function SpecEdit
{
	Debug '(SpecEdit)'
	if [ $# -ne 1 ] || [ -z "$1" ]
	then
		Error "(SpecEdit) Usage: $0 SpecEdit <file>"
		return 1
	fi
	# -e option : edit the spec file
	local File
	File=$1
	${VISUAL:-${EDITOR:-vi}} "$File"
	AskYesNo "$WantContinue" || {
		Aborted="yes"
		export Aborted
		Echo "Aborted."
	        return 1
	}
	return 0
}
###############################################################################
# check for package change
function VerifyPackage
{
	Debug "(VerifyPackage) ${RPMREBUILD_PAQUET}"
	rpm --verify --nodeps "$RPMREBUILD_PAQUET" # Don't return here, st=1 - verify fail
	return 0
}
###############################################################################
# ask question to user if necessary
function QuestionsToUser
{
	Debug '(QuestionsToUser)'
	[ "$RPMREBUILD_batch"     = "yes" ] && return 0 ## batch mode, continue
	[ "$RPMREBUILD_spec_only" = "yes" ] && return 0 ## spec only mode, no questions

	AskYesNo "$WantContinue" || {
		Aborted="yes"
		export Aborted
		return 1
	}
	local RELEASE_ORIG
	RELEASE_ORIG="$(spec_query qf_spec_release )"
	[ -z "$RELEASE_NEW" ] && \
	AskYesNo "$WantChangeRelease" && {
		read -r -p "$EnterRelease $RELEASE_ORIG): " RELEASE_NEW
	}
	return 0
}
###############################################################################
# check if the given name match an installed rpm package
function IsPackageInstalled
{
	Debug '(IsPackageInstalled)'
	# test if package exists
	local output
	output=$( rpm --query "${RPMREBUILD_PAQUET}" 2>&1 ) # Don't return here - use output
	if [ "$?" -eq 1 ]
	then
		# no such package in rpm database
		Error "(IsPackageInstalled) ${RPMREBUILD_PAQUET} $PackageNotInstalled"
		return 1
	else
		# find it : one or more ?
		# shellcheck disable=SC2086
		set -- $output
		case $# in
			1)
			: # Ok, do nothing
			;;

			*)
				Error "(IsPackageInstalled) $PackageTooMuch '${RPMREBUILD_PAQUET}':\n$output"
			return 1
			;;
		esac 
	fi
	return 0
}
###############################################################################
# for rpm file cpio bigger than 4GB, use rpm2archive to process and convert to cpio for further process
function ProcessTar {
	local ARCHIVE_TEMP="$1"
	local ARCHIVE_EXTRACT_DIR="$TMPDIR_WORK/root"

	[ -e "$ARCHIVE_TEMP" ] || {
		Error "(ProcessTar) ProcessTar failed, required file not found"
		exit 1
	}
	[ -e "$ARCHIVE_EXTRACT_DIR" ] || mkdir -p "$ARCHIVE_EXTRACT_DIR"

	echo "ARCHIVE_TEMP: $ARCHIVE_TEMP"
	echo "ARCHIVE_EXTRACT_DIR: $ARCHIVE_EXTRACT_DIR"
	echo "Contents of $ARCHIVE_EXTRACT_DIR:"
	ls -la "$TMPDIR_WORK"
	echo "Size of $ARCHIVE_EXTRACT_DIR:"
	echo $(du -sh $ARCHIVE_EXTRACT_DIR)

	Debug "Running tar -xf $ARCHIVE_TEMP -C $ARCHIVE_EXTRACT_DIR"
	tar -xf "$ARCHIVE_TEMP" -C "$ARCHIVE_EXTRACT_DIR" || {
		Error "（ProcessTar） Extraction of tar file failed "
		exit 1
	}
	echo $(du -sh $ARCHIVE_EXTRACT_DIR)
	echo "Here is the size of extracted files"
}

###############################################################################
# for rpm file, we have to extract files to BUILDROOT directory but this time is tgz
function RpmUnpackTGZ {
    local ARCHIVE_TEMP="$TMPDIR_WORK/temp_archive.tgz"
    local PAQUETGZ="${RPMREBUILD_PAQUET}.tgz"
    rpm2archive "${RPMREBUILD_PAQUET}" && mv "$PAQUETGZ" "$ARCHIVE_TEMP" && ProcessTar "$ARCHIVE_TEMP" || {
		Error "(RpmUnpack) rpm2cpio and rpm2archive failed"
		return 1
	}
	rm --force "$PAQUETGZ" || return
	echo "Ready for further processing"
	/bin/bash "$MY_LIB_DIR"/rpmrebuild_ghost.sh "$BUILDROOT" <"$FILES_IN" || return
	return 0
}

###############################################################################
# for rpm file, we have to extract files to BUILDROOT directory
function RpmUnpack {
	Debug '(RpmUnpack)'
	# do not install files on /
	[ "x$BUILDROOT" = "x/" ] && {
		Error "(RpmUnpack) $BuildRootError"
		return 1
	}
    local CPIO_TEMP=$TMPDIR_WORK/temp_archive.cpio
    echo "Unpacking: ${RPMREBUILD_PAQUET}"
    rm --force "$CPIO_TEMP" || return
    rpm2cpio "${RPMREBUILD_PAQUET}" >"$CPIO_TEMP" || {
		# If rpm2cpio fails, try using rpm2archive
		echo "(RpmUnpack) rpm2cpio failed, trying rpm2archive,this might take long time"
		rm --force "$CPIO_TEMP" || return
		RpmUnpackTGZ
		return
	}

	rm --force --recursive "$BUILDROOT" || return
	Mkdir_p "$BUILDROOT" || return
	(cd "$BUILDROOT" && cpio --quiet -idmu --no-absolute-filenames) <"$CPIO_TEMP" || {
		Error "(RpmUnpack) cpio"
		return 1
	}
	rm --force "$CPIO_TEMP" || return
	# Process ghost files
	/bin/bash "$MY_LIB_DIR"/rpmrebuild_ghost.sh "$BUILDROOT" <"$FILES_IN" || return
	return 0
}
###############################################################################
# create buildroot if necessary
function CreateBuildRoot
{
	Debug '(CreateBuildRoot)'
        if [ -z "$RPMREBUILD_package_flag" ]; then
		# installed package
		if [ "$need_change_files" = "yes" ]; then
			/bin/bash "$MY_LIB_DIR"/rpmrebuild_buildroot.sh "$BUILDROOT" < "$FILES_IN" || Error "(CreateBuildRoot) rpmrebuild_buildroot.sh $BUILDROOT" || return
		else
			: # Do nothing (avoid a copy)
		fi
	else
		# rpm file
		RpmUnpack || Error "(CreateBuildRoot) RpmUnpack" || return
	fi 
	return 0
}
###############################################################################
# get architecture from package to build
function RpmArch
{
	Debug '(RpmArch)'
	pac_arch=$( spec_query qf_spec_arch )
	return;
}
###############################################################################
# detect if package arch is not the same as os architecture
# and set change_arch if necessary
function CheckArch
{
	Debug '(CheckArch)'
	# current architecture
	local cur_arch
	cur_arch=$( uname -m)

	# pac_arch is got from RpmArch
	RpmArch
	case $pac_arch in
	"$cur_arch")
		change_arch="";;
	noarch)
		change_arch="";;
	'(none)')
		change_arch="";;
	*)
		change_arch="setarch $pac_arch";;
	esac
	Debug "  change_arch=$change_arch"
	return

}
###############################################################################
# build rpm package using rpmbuild command
function RpmBuild
{
	Debug '(RpmBuild)'
	# rpmrebuild package dependency
	# for rpm 3.x : use rpm
	# for rpm 4.x : use rpmbuild
	local BUILDCMD
	if [ -x /usr/bin/rpmbuild ]
	then
		BUILDCMD=/usr/bin/rpmbuild
	else

		BUILDCMD=rpm
	fi

	# rpm 4.6 ignore BuildRoot in the spec file, 
	# so I have to provide define on the command line
	# Worse, it disallow buildroot "/", so I have to trick it.
	# a first easy answer is with a symbolic link
	# but it fails for filesystem package who owned / directory
	# this is fixed in rpmrebuild_files.sh
	# another may be with : mount --bind -o ro / $BUILDROOT
	# but if does not work if not superuser
	# and need also to mount all other filesystems (/usr /var ...)
	if [ "$BUILDROOT" = "/" ]; then
		BUILDROOT="${RPMREBUILD_TMPDIR}/my_root"
		# Just in case previous link is here
		rm -f "$BUILDROOT" || return
		# Trick rpm (I hope :)
		ln -s / "$BUILDROOT" || {
			Error "(RpmBuild) ${BUILDROOT} $LinkFailed"
			return 1
		}
	fi
	eval "$change_arch" $BUILDCMD --define "'buildroot $BUILDROOT'" "$RPMREBUILD_rpm_defines" -bb "$RPMREBUILD_rpm_verbose" "$RPMREBUILD_additional" "${FIC_SPEC}" || {
		Error "(RpmBuild) package '${RPMREBUILD_PAQUET}' $BuildFailed"
		return 1
	}
	
	return 0
}
###############################################################################
# try to guess full package name
function RpmFileName
{
	Debug '(RpmFileName)'
	local QF_RPMFILENAME
	QF_RPMFILENAME=$(eval "$change_arch" rpm "$RPMREBUILD_rpm_defines" --eval %_rpmfilename) || return
	#Debug "    QF_RPMFILENAME=$QF_RPMFILENAME"
	# from generated specfile
	RPMFILENAME=$(eval "$change_arch" rpm "$RPMREBUILD_rpm_defines" --specfile --query --queryformat "${QF_RPMFILENAME}" "${FIC_SPEC}") || return

	# workaround for redhat 6.x / rpm 3.x
	local arch
	arch=$(eval "$change_arch" rpm "$RPMREBUILD_rpm_defines" --specfile --query --queryformat "%{ARCH}"  "${FIC_SPEC}")
	if [ "$arch" = "(none)" ]
	then
		Debug '    workaround for rpm 3.x'
		# get info from original paquet
		# will work if no changes in spec (release ....)
		#arch=$(eval $change_arch rpm $RPMREBUILD_rpm_defines --query $RPMREBUILD_package_flag --queryformat "%{ARCH}" ${RPMREBUILD_PAQUET})
		#RPMFILENAME=$(echo $RPMFILENAME | sed "s/(none)/$arch/g")
		RPMFILENAME=$(eval "$change_arch" rpm "$RPMREBUILD_rpm_defines" --query --queryformat "${QF_RPMFILENAME}" "${RPMREBUILD_PAQUET}") || return
	fi

	[ -n "$RPMFILENAME" ] || return
	RPMFILENAME="${RPMREBUILD_rpmdir}/${RPMFILENAME}"
	if [ ! -f "${RPMFILENAME}" ]
	then
		Error "(RpmFileName) $FileNotFound rpm $RPMFILENAME"
		ls -ltr "${RPMREBUILD_rpmdir}/${pac_arch}/${RPMREBUILD_PAQUET}*"
		return 1
	fi
	return 0
}

###############################################################################
# -U or -i option ? : -U does work if only a version is installed
function IsMultiInstall
{
	# get package name
	local package_name
	package_name=$( rpm -qp --queryformat '%{NAME}' "${RPMFILENAME}" )
	# count installs
	rpm -q "${package_name}" 2> /dev/null | wc -l
}
###############################################################################
# test if build package can be installed
function InstallationTest
{
	Debug '(InstallationTest)'
	# installation test
	# force is necessary to avoid the message : already installed
	local rpm_options
	rpm_options='--test --force'
	local nb
	nb=$( IsMultiInstall )
	if [ "$nb" -le 1 ]
	then
		rpm_options="$rpm_options -U"
	else
		Debug "multi-installed package"
		rpm_options="$rpm_options -i"
	fi
	# shellcheck disable=SC2086
	rpm ${rpm_options} "${RPMFILENAME}" || {
		Error "(InstallationTest) package '${RPMREBUILD_PAQUET}' $TestFailed"
		return 1
	}
	Debug "(InstallationTest) test install ${RPMREBUILD_PAQUET} ok"
	return 0
}
###############################################################################
# install the package
function Installation
{
	Debug '(Installation)'
	# chek if root
	local ID
	ID=$( id -u )
	if [ "$ID" -eq 0 ]
	then
		local rpm_options
		rpm_options='-v -h --force'
		local nb
		nb=$( IsMultiInstall )
		if [ "$nb" -le 1 ]
		then
			rpm_options="$rpm_options -U"
		else
			rpm_options="$rpm_options -i"
		fi
		# shellcheck disable=SC2086
		rpm ${rpm_options} "${RPMFILENAME}" || {
			Error "(Installation) package '${RPMREBUILD_PAQUET}' $InstallFailed"
			return 1
		}
		return 0
	else
		Error "(Installation) package '${RPMREBUILD_PAQUET}' $InstallCannot"
		return 1
	fi
}
###############################################################################
# execute all pre-computed operations on spec files
function Processing
{
	Debug '(Processing)'

	source "$RPMREBUILD_PROCESSING" && return 0

	if [ "$need_change_spec" = "yes" ] || [ "$need_change_files" = "yes" ]; then
		[ "$Aborted" = "yes" ] || Error "(Processing) package '$RPMREBUILD_PAQUET' $ModificationFailed."
	else
		Error "(Processing) package '$RPMREBUILD_PAQUET' $SpecFailed."
	fi
	return 1
}
###############################################################################
# recover system informations on rpm/rpmrebuild context
function GetInformations
{
	Debug '(GetInformations)'
	Echo "from: $1"
	Echo "-----------"
	lsb_release -a
	cat /etc/issue
	Echo "-----------"
	rpm -q rpmrebuild
	rpm -q rpm
	#Echo "RPMREBUID_OPTS=$RPMREBUILD_OPTS"
	Echo "-----------"
	Echo "$RPM_TAGS"
	Echo " --------------- $WriteComments -----------------------"
}
###############################################################################
# send informations to developper to allow fix problems
function SendBugReport
{
	Debug '(SendBugReport)'
	[ "$RPMREBUILD_batch"     = "yes" ] && return 0 ## batch mode, skip report

	[ -s "$RPMREBUILD_BUGREPORT" ] || return 0 ## empty report

	AskYesNo "$WantSendBugReport" || return
	# build default mail address 
	local from
	from="${USER}@${HOSTNAME}"
	AskYesNo "$WantChangeEmail ($from)" && {
		read -r -p "$EnterEmail" from
	}
	GetInformations "$from" >> "$RPMREBUILD_BUGREPORT" 2>&1
	AskYesNo "$WantEditReport" && {
		${VISUAL:-${EDITOR:-vi}} "$RPMREBUILD_BUGREPORT"
	}
	AskYesNo "$WantStillSend" && {
		mail -s "[rpmrebuild] bug report" rpmrebuild-bugreport@lists.sourceforge.net < "$RPMREBUILD_BUGREPORT"
	}
	return
}
###############################################################################
# search if the given tag exists in current rpm release
function SearchTag
{
	local tag
	tag=$1
	for rpm_tag in $RPM_TAGS
	do
		if [ "$tag" = "$rpm_tag" ]
		then
			# ok : we find it
			return 0
			fi	
	done
	return 1
}
###############################################################################
# change rpm query file (sed)
# and save all intermediate by using si_rpmqf counter
function ChangeRpmQf
{
	Debug "(ChangeRpmQf) $1"
	local SED_PAR
	SED_PAR=$1
	local input_rpmqf
	input_rpmqf=$TMPDIR_WORK/rpmrebuild_rpmqf.src.$si_rpmqf
	si_rpmqf=$(( si_rpmqf + 1 ))
	local output_rpmqf
	output_rpmqf=$TMPDIR_WORK/rpmrebuild_rpmqf.src.$si_rpmqf
	sed -e "$SED_PAR" < "$input_rpmqf" > "$output_rpmqf"

	return 0
}
###############################################################################
# generate rpm query file according current rpm tags
# used to fix strange behavior
# remove optionnals tags not available
function GenRpmQf
{
	Debug '(GenRpmQf)'
	#RPM_TAGS=$( cat /home/eric/projets/rpmrebuild/rpmtags/querytags.RedHat6.1_rpm3.0.3 ) || return
	RPM_TAGS=$( rpm --querytags ) || return

	# base code
	cp "${MY_LIB_DIR}"/rpmrebuild_rpmqf.src "${TMPDIR_WORK}"/rpmrebuild_rpmqf.src.$si_rpmqf

	local optional_file
	optional_file=$MY_LIB_DIR/optional_tags.cfg
	if [ -f "$optional_file" ]
	then
		local tag1 type tag2
		while read -r tag1 type tag2
		do
			local tst_comment
			tst_comment=$( echo "$tag1" | grep '#' )
			if [ -z "$tst_comment" ]
			then
			SearchTag "$tag1" || {
				case "$type" in
				d_line)
					ChangeRpmQf "/%{$tag1}/d"
					Echo "(GenRpmQf) $RemoveTagLine $tag1"
					;;
				d_word)
					ChangeRpmQf "s/%{$tag1}//g"
					Echo "(GenRpmQf) $RemoveTagWord $tag1"
					;;
				replacedby)
					#Echo "tag1=$tag1 type=$type tag2=$tag2"
					[ -n "$tag2" ] && SearchTag "$tag2" && ChangeRpmQf "s/$tag1/$tag2/g" && Echo "(GenRpmQf) $ReplaceTag $tag1 => $tag2"
					;;
				*)
					Warning "(GenRpmQf) $UnknownType $type"
					;;
				esac

			}
			fi
		done < "$optional_file"
	else
		Warning "(GenRpmQf) $FileNotFound $optional_file"
	fi

	return 0
}
###############################################################################
# rpm tags change along the time : some are added, some are renamed, some are
# deprecated, then removed
# the idea is to check if the tag we use for rpmrebuild still exists
function CheckTags
{
	Debug '(CheckTags)'
	# list of used tags
	#Echo "(CheckTags) search tags in rpmrebuild_rpmqf.src.$si_rpmqf"
	local rpmrebuild_tags
	rpmrebuild_tags=$( "${MY_LIB_DIR}"/rpmrebuild_extract_tags.sh "${TMPDIR_WORK}"/rpmrebuild_rpmqf.src.$si_rpmqf )

	# check for all rpmrebuild tags
	local errors
	errors=0
	for tag in $rpmrebuild_tags
	do
		SearchTag "$tag" || {
			Warning "(CheckTags) $MissingTag $tag"
			errors=$(( errors + 1 ))
		}
	done
	if [ "$errors" -ge 1 ]
	then
		Warning "$CannotWork"
		return 1
	fi
}
##############################################################
# test if --i18ndomains option is available
# to be used in spec_query function
function check_i18ndomains
{
	Debug '(check_i18ndomains)'
	rpm --query --i18ndomains /dev/null rpm > /dev/null 2>&1
	if [ "$?" -eq 0 ]
	then
		i18ndomains='--i18ndomains /dev/null'
	else
		i18ndomains=''
	fi
}
##############################################################
# in debug mode , we do not clean temp files
function clean_exit
{
	if [ -z "$RPMREBUILD_debug" ]
	then
		RmDir "$RPMREBUILD_TMPDIR"
	else
		Debug "workdir : $TMPDIR_WORK"
		ls -altr "$TMPDIR_WORK"
	fi
}
##############################################################
# on signal clean as usual
function sig_prgm
{
	clean_exit
	exit 1
}
##############################################################
# Main Part                                                  #
##############################################################
# shell pour refabriquer un fichier rpm a partir de la base rpm
# a shell to build an rpm file from the rpm database

function Main
{
	RPMREBUILD_TMPDIR=${RPMREBUILD_TMPDIR:-~/.tmp/rpmrebuild.$$}
	RPMREBUILD_BUGREPORT=${RPMREBUILD_TMPDIR}/bugreport
	export RPMREBUILD_BUGREPORT
	export RPMREBUILD_TMPDIR
	TMPDIR_WORK=${RPMREBUILD_TMPDIR}/work

	MY_LIB_DIR=$( dirname "$0" ) || ( echo "ERROR rpmrebuild.sh dirname $0"; exit 1)
	source "${MY_LIB_DIR}/rpmrebuild_lib.src"    || ( echo "ERROR rpmrebuild.sh source $MY_LIB_DIR/rpmrebuild_lib.src" ; exit 1)

	# create tempory directories before any work/test
	RmDir "$RPMREBUILD_TMPDIR" || Error "RmDir $RPMREBUILD_TMPDIR" || return
	Mkdir_p "$TMPDIR_WORK"     || Error "Mkdir_p $TMPDIR_WORK" || return

	# get VERSION
	GetVersion

	FIC_SPEC=${TMPDIR_WORK}/spec
	FILES_IN=${TMPDIR_WORK}/files.in
	# I need it here just in case user specify 
	# plugins for fs modification  (--change-files)
	BUILDROOT=${TMPDIR_WORK}/root

	source "$MY_LIB_DIR"/rpmrebuild_parser.src || Error "source $MY_LIB_DIR/rpmrebuild_parser.src" || return
	source "$MY_LIB_DIR"/spec_func.src         || Error "source $MY_LIB_DIR/spec_func.src" || return
	source "$MY_LIB_DIR"/processing_func.src   || Error "source $MY_LIB_DIR/processing_func.src" || return

	# check language
	case "$LANG" in
		en*) real_lang=en;;
		fr_FR) real_lang=$LANG;;
		fr_FR.UTF-8) real_lang=$LANG;;
		*)  real_lang=en;;
	esac
	# load translation file
	# shellcheck source=locale/en/rpmrebuild.lang
	source "$MY_LIB_DIR/locale/$real_lang/rpmrebuild.lang"
	
	RPMREBUILD_PROCESSING=$TMPDIR_WORK/PROCESSING
	processing_init || return
	CommandLineParsing "$@" || return
	[ -z "$NEED_EXIT" ] || return "$NEED_EXIT"

	Debug "rpmrebuild version $VERSION : $*"
	environment=$( env | sort )
	Debug "environment : $environment"

	check_i18ndomains

	# generate rpm query file 
	GenRpmQf || return
	# check it
	CheckTags || return
	# and load it
	source "${TMPDIR_WORK}/rpmrebuild_rpmqf.src.$si_rpmqf"   || return

	export RPMREBUILD_PLUGINS_DIR=${MY_LIB_DIR}/plugins

	# to solve problems of bad date
	export LC_TIME=POSIX

	if [ -z "$RPMREBUILD_package_flag" ]; then
		[ "$need_change_files" = "yes" ] || BUILDROOT="/"
   		IsPackageInstalled || return
		if [ "$RPMREBUILD_verify" = "yes" ]; then
			out=$(VerifyPackage) || return
			if [ -n "$out" ]; then
		 		Warning "$FilesModified\n$out"
		 		QuestionsToUser || return
			fi
		else # NoVerify
			:
		fi
	else
		:
		# When rebuilding package from .rpm file it's just native
		# to use perm/owner/group from the package.
		# But because it anyway default and if one has a reason
		# to change it, one can. I am not force it here anymore.
		#RPMREBUILD_PUG_FROM_FS="no"  # Be sure use perm, owner, group from the pkg query.
	fi

	if [ "$RPMREBUILD_spec_only" = "yes" ]; then
		BUILDROOT="/"
		SpecGeneration   || Error "SpecGeneration" || return
		Processing       || Error "Processing" || return
		Echo "specfile: $RPMREBUILD_specfile"
	else
		SpecGeneration   || Error "SpecGeneration" || return
		CreateBuildRoot  || Error "CreateBuildRoot" || return
		Processing       || Error "Processing" || return
		CheckArch	 || Error "CheckArch" || return
		RpmBuild         || Error "RpmBuild" || return
		RpmFileName      || Error "RpmFileName" || return
		Echo "result: ${RPMFILENAME}"
		if [ -z "$RPMREBUILD_NOTESTINSTALL" ]; then
			InstallationTest || Error "InstallationTest" || return
		fi
		if [ -n "$RPMREBUILD_package_install" ]; then
			Installation || Error "Installation" || return
		fi
	fi
	return 0
}
###############################################################################

trap 'sig_prgm' 1 2 3 15

Main "$@"
st=$?	# save status

# bug report ?
if [ "$Aborted" = "no" ]
then
	SendBugReport
fi

# in debug mode , we do not clean temp files
clean_exit

exit $st

#####################################
# BUILDROOT note.
# My original idea was for recreating package from another rpm file
# (not installed) use 'rpm -bb --define "buildroot foo"', but
# It does not work:
#  when i not specify buildroot in the spec file default value is "/"
#  I can build this package, but can't override buildroot from the
#  command line.
#
# when i specify buildroot: / in the spec file i got parser error.
#
# So, for recreating installed packages I need specfile WITHOUT
# buildroot
# For recreating package from another rpm I have to put buildroot in the
# specfile
#########################################
