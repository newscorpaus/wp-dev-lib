#!/bin/bash

set -e
shopt -s expand_aliases

function upsearch {
	# via http://unix.stackexchange.com/a/13474
	slashes=${PWD//[^\/]/}
	directory="./"
	for (( n=${#slashes}; n>0; --n )); do
		test -e "$directory/$1" && echo "$directory/$1" && return
		if [ "$2" != 'git_boundless' ] && test -e '.git'; then
			return
		fi
		directory="$directory/.."
	done
}

function verbose_arg {
	if [ "$VERBOSE" == 1 ]; then
		echo '-v'
	fi
}

function download {
	if command -v curl >/dev/null 2>&1; then
		curl $(verbose_arg) -L -s "$1" > "$2"
	elif command -v wget >/dev/null 2>&1; then
		wget $(verbose_arg) -n -O "$2" "$1"
	else
		echo ''
		exit 1
	fi
}

function phpcs_tests {
	if [ -z "$WPCS_STANDARD" ]; then
		echo "Skipping PHPCS since WPCS_STANDARD (and PHPCS_RULESET_FILE) is empty."
		return
	fi

	if ! command -v phpcs >/dev/null 2>&1; then
		echo "Downloading PHPCS phar"
		download https://phar.phpunit.de/phpunit.phar /tmp/phpunit.phar
		chmod +x /tmp/phpunit.phar
		alias phpunit='/tmp/phpunit.phar'
	fi
}


function install_wp {

	if [ -d "$WP_CORE_DIR" ]; then
		return 0
	fi
	if ! command -v svn >/dev/null 2>&1; then
		echo "install_wp failure: svn is not installed"
		return 1
	fi

	if [ "$WP_VERSION" == 'latest' ]; then
		local TAG=$( svn ls https://develop.svn.wordpress.org/tags | tail -n 1 | sed 's:/$::' )
		local SVN_URL="https://develop.svn.wordpress.org/tags/$TAG/"
	elif [ "$WP_VERSION" == 'trunk' ]; then
		local SVN_URL=https://develop.svn.wordpress.org/trunk/
	else
		local SVN_URL="https://develop.svn.wordpress.org/tags/$WP_VERSION/"
	fi

	echo "Installing WP from $SVN_URL to $WP_CORE_DIR"

	svn export -q "$SVN_URL" "$WP_CORE_DIR"

	download https://raw.github.com/markoheijnen/wp-mysqli/master/db.php "$WP_CORE_DIR/src/wp-content/db.php"
}

function install_test_suite {
	# portable in-place argument for both GNU sed and Mac OSX sed
	if [[ $(uname -s) == 'Darwin' ]]; then
		local ioption='-i .bak'
	else
		local ioption='-i'
	fi

	cd "$WP_CORE_DIR"

	if [ ! -f wp-tests-config.php ]; then
		cp wp-tests-config-sample.php wp-tests-config.php
		sed $ioption "s/youremptytestdbnamehere/$DB_NAME/" wp-tests-config.php
		sed $ioption "s/yourusernamehere/$DB_USER/" wp-tests-config.php
		sed $ioption "s/yourpasswordhere/$DB_PASS/" wp-tests-config.php
		sed $ioption "s|localhost|${DB_HOST}|" wp-tests-config.php
	fi

}

function install_db {
	if ! command -v mysqladmin >/dev/null 2>&1; then
		echo "install_db failure: mysqladmin is not present"
		return 1
	fi

	# parse DB_HOST for port or socket references
	local PARTS=(${DB_HOST//\:/ })
	local DB_HOSTNAME=${PARTS[0]};
	local DB_SOCK_OR_PORT=${PARTS[1]};
	local EXTRA=""

	if ! [ -z "$DB_HOSTNAME" ] ; then
		if [ $(echo "$DB_SOCK_OR_PORT" | grep -e '^[0-9]\{1,\}$') ]; then
			EXTRA=" --host=$DB_HOSTNAME --port=$DB_SOCK_OR_PORT --protocol=tcp"
		elif ! [ -z "$DB_SOCK_OR_PORT" ] ; then
			EXTRA=" --socket=$DB_SOCK_OR_PORT"
		elif ! [ -z "$DB_HOSTNAME" ] ; then
			EXTRA=" --host=$DB_HOSTNAME --protocol=tcp"
		fi
	fi

	# drop the database if it exists
	mysqladmin drop -f "$DB_NAME" --silent --no-beep --user="$DB_USER" --password="$DB_PASS"$EXTRA || echo "$DB_NAME does not exist yet"

	# create database
	mysqladmin create "$DB_NAME" --user="$DB_USER" --password="$DB_PASS"$EXTRA

	echo "DB $DB_NAME created"
}

function phpunit_tests {
	echo
	echo "## PHPUnit tests"

	# @todo We need to be able to run these in Vagrant instead, including the exporting of the environment variables

	if [ -z "$PHPUNIT_CONFIG" ]; then
		echo "Skipping since PHPUNIT_CONFIG is empty."
		return
	fi

	if [ "$PROJECT_TYPE" != plugin ]; then
		echo "Skipping since currently only applies to plugins"
		return
	fi

	if [ "$PROJECT_TYPE" == plugin ]; then
		INSTALL_PATH="$WP_CORE_DIR/src/wp-content/plugins/$PROJECT_SLUG"
	fi

	WP_TESTS_DIR=${WP_CORE_DIR}/tests/phpunit   # This is a bit of a misnomer: it is the *PHP* tests dir
	export WP_CORE_DIR
	export WP_TESTS_DIR

	# @todo Only do this if there are PHP files that are changed

	# Install the WordPress Unit Tests
	if [ "$WP_INSTALL_TESTS" == 'true' ]; then
		if ! install_wp; then
			return
		fi
		if ! install_test_suite; then
			return
		fi
		if ! install_db; then
			return
		fi
	fi

	# Rsync the files into the right location
	mkdir -p "$INSTALL_PATH"
	rsync -a $(verbose_arg) --exclude .git/hooks --delete "$PROJECT_DIR/" "$INSTALL_PATH/"
	cd "$INSTALL_PATH"

	# Remove untracked files when not working with
	if [ "$DIFF_HEAD" != 'WORKING' ]; then
		git clean -d --force --quiet
	fi
	if [ "$DIFF_HEAD" == 'STAGE' ]; then
		git checkout .
	fi
	git status

	# @todo Delete files that are not in Git?
	echo "Location: $INSTALL_PATH"

	if ! command -v phpunit >/dev/null 2>&1; then
		echo "Downloading PHPUnit phar"
		download https://phar.phpunit.de/phpunit.phar /tmp/phpunit.phar
		chmod +x /tmp/phpunit.phar
		alias phpunit='/tmp/phpunit.phar'
	fi

	# Run the tests
	phpunit $(verbose_arg) --configuration "$PHPUNIT_CONFIG"
	cd - > /dev/null
}

# Abort if the script is being sourced into another script.
if [ "$( basename "$0" )" != 'check-diff.sh' ]; then
	return
fi

################################################################################

DEV_LIB_PATH=${DEV_LIB_PATH:-$( dirname "$0" )/}
PROJECT_DIR=${PROJECT_DIR:-$( git rev-parse --show-toplevel )}
PROJECT_SLUG=${PROJECT_SLUG:-$( basename "$PROJECT_DIR" | sed 's/^wp-//' )}
PATH_INCLUDES=${PATH_INCLUDES:-./}

if [ -z "$PROJECT_TYPE" ]; then
	if [ -e style.css ]; then
		PROJECT_TYPE=theme
	elif grep -isqE "^[     ]*\*[     ]*Plugin Name[     ]*:" "$PROJECT_DIR"/*.php; then
		PROJECT_TYPE=plugin
	else
		PROJECT_TYPE=unknown
	fi
fi

# Formerly LIMIT_TRAVIS_PR_CHECK_SCOPE
CHECK_SCOPE=${CHECK_SCOPE:-patches} # 'all', 'changed-files', 'patches'

DIFF_BASE=${DIFF_BASE:-HEAD}
DIFF_HEAD=${DIFF_HEAD:-WORKING}

# treeishA to treeishB (git diff treeishA...treeishB)
# treeish to STAGE (git diff --staged treeish)
# HEAD to WORKING [default] (git diff HEAD)

# @todo DIFF_HEAD=WORKING

PHPCS_PHAR_URL=https://squizlabs.github.io/PHP_CodeSniffer/phpcs.phar
PHPCS_RULESET_FILE=$( upsearch phpcs.ruleset.xml )
PHPCS_IGNORE=${PHPCS_IGNORE:-'vendor/*'}

TRAVIS=true
if [ -z "$PHPUNIT_CONFIG" ]; then
	if [ -e phpunit.xml ]; then
		PHPUNIT_CONFIG=phpunit.xml
	elif [ -e phpunit.xml.dist ]; then
		PHPUNIT_CONFIG=phpunit.xml.dist
	fi
fi

WPCS_DIR=${WPCS_DIR:-/tmp/wpcs}
WPCS_GITHUB_SRC=${WPCS_GITHUB_SRC:-WordPress-Coding-Standards/WordPress-Coding-Standards}
WPCS_GIT_TREE=${WPCS_GIT_TREE:-master}

if [ -z "$WPCS_STANDARD" ]; then
	if [ ! -z "$PHPCS_RULESET_FILE" ]; then
		WPCS_STANDARD="$PHPCS_RULESET_FILE"
	else
		WPCS_STANDARD="WordPress-Core"
	fi
fi

DB_HOST=${DB_HOST:-localhost}
DB_NAME=${DB_NAME:-wordpress_test}
DB_USER=${DB_USER:-root}
DB_PASS=${DB_PASS:-root}

if [ -z "$WP_INSTALL_TESTS" ]; then
	if [ "$TRAVIS" == true ]; then
		WP_INSTALL_TESTS=true
	else
		WP_INSTALL_TESTS=false
	fi
fi
WP_CORE_DIR=${WP_CORE_DIR:-/tmp/wordpress}
WP_VERSION=${WP_VERSION:-latest}

YUI_COMPRESSOR_CHECK=${YUI_COMPRESSOR_CHECK:-1}
DISALLOW_EXECUTE_BIT=${DISALLOW_EXECUTE_BIT:-0}

VERBOSE=${VERBOSE:-0}
# @todo CODECEPTION_CHECK=1

if [ -z "$JSCS_CONFIG" ]; then
	JSCS_CONFIG="$( upsearch .jscsrc )"
fi
if [ -z "$JSCS_CONFIG" ]; then
	JSCS_CONFIG="$( upsearch .jscs.json )"
fi

# Load any environment variable overrides from config files
ENV_FILE=$( upsearch .ci-env.sh )
if [ ! -z "$ENV_FILE" ]; then
	source "$ENV_FILE"
fi
ENV_FILE=$( upsearch .dev-lib )
if [ ! -z "$ENV_FILE" ]; then
	source "$ENV_FILE"
fi

# Parse arguments from command line to set environment variables
while [[ $# > 0 ]]; do
	key="$1"
	case "$key" in
		-b|--diff-base)
			DIFF_BASE="$2"
			shift # past argument
		;;
		-h|--diff-head)
			DIFF_HEAD="$2"
			shift # past argument
		;;
		-s|--scope)
			CHECK_SCOPE="$2"
			shift # past argument
		;;
		-i|--ignore-paths)
			IGNORE_PATHS="$2"
			shift # past argument
		;;
		-v|--verbose)
			VERBOSE=1
		;;
		--HELP)
			HELP=1
		;;
		*)
			# unknown option
		;;
	esac
	shift # past argument or value
done

if [ ! -z "$HELP" ]; then
	echo "TODO: Help"
	exit 0
fi

if [ "$DIFF_HEAD" == 'INDEX' ]; then
	DIFF_HEAD='STAGE'
fi

if [ "$DIFF_BASE" == 'HEAD' ] && [ "$DIFF_HEAD" != 'STAGE' ] && [ "$DIFF_HEAD" != 'WORKING' ]; then
	echo "Error: when DIFF_BASE is 'HEAD' then DIFF_HEAD must be 'STAGE' or 'WORKING' (you supplied '$DIFF_HEAD')" 1>&2
	exit 1
fi
if [ "$DIFF_HEAD" == 'WORKING' ] && [ "$DIFF_BASE" != 'STAGE' ] && [ "$DIFF_BASE" != 'HEAD' ]; then
	echo "Error: when DIFF_HEAD is 'WORKING' then DIFF_BASE must be 'STAGE' or 'HEAD' (you supplied '$DIFF_BASE')" 1>&2
	exit 1
fi

CHECK_SCOPE=$( tr '[A-Z]' '[a-z]' <<< "$CHECK_SCOPE" )
if [ "$CHECK_SCOPE" != 'all' ] && [ "$CHECK_SCOPE" != 'changed-files' ] && [ "$CHECK_SCOPE" != 'patches' ]; then
	echo "Error: CHECK_SCOPE must be 'all', 'changed-files', or 'patches'" 1>&2
	exit 1
fi

if [ "$VERBOSE" == 1 ]; then
	echo 1>&2
	echo "## CONFIG VARIABLES" 1>&2

	# List obtained via ack -o '[A-Z][A-Z0-9_]*(?==)' | tr '\n' ' '
	for var in DEV_LIB_PATH PROJECT_DIR PROJECT_SLUG PATH_INCLUDES PROJECT_TYPE CHECK_SCOPE DIFF_BASE DIFF_HEAD PHPCS_DIR PHPCS_GITHUB_SRC PHPCS_GIT_TREE PHPCS_RULESET_FILE PHPCS_IGNORE WPCS_DIR WPCS_GITHUB_SRC WPCS_GIT_TREE WPCS_STANDARD WP_CORE_DIR WP_TESTS_DIR YUI_COMPRESSOR_CHECK DISALLOW_EXECUTE_BIT CODECEPTION_CHECK JSCS_CONFIG JSCS_CONFIG ENV_FILE ENV_FILE DIFF_BASE DIFF_HEAD CHECK_SCOPE IGNORE_PATHS HELP VERBOSE DB_HOST DB_NAME DB_USER DB_PASS WP_INSTALL_TESTS; do
		echo "$var=${!var}" 1>&2
	done
	echo 1>&2
fi

# get staged file contents: http://stackoverflow.com/questions/5153199/git-show-content-of-file-as-it-will-look-like-after-committing

phpunit_tests

