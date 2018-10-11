#!/usr/bin/env bash

# script version
readonly VERSION="0.0.2"

# usage:
#
# _xe_command "command to forward to xe"
# sample:
# _xe_command "host-list"
#
# set response to variable XE_RESPONSE
# exit on error
# don't use this function in a subshell!
#
_xe_command()
{
  local xe_cmd
  local xe_code
  xe_cmd="${XE_BIN} $1"
  [ "${DEBUG}" == "yes" ] && echo "[DEBUG] command: ${xe_cmd}" >&2
  XE_RESPONSE=$(echo "${xe_cmd}" | bash)
  xe_code=$?
  if [ ${xe_code} -ne 0 ]; then
    exit ${xe_code}
  fi

  return ${xe_code}
}

_title()
{
  echo -e "\\n== $1 ==\\n"
}

check_updates_database()
{
  if [ ! -f "${PATCHES_DATABASE}" ]; then
    echo -e "\\nRequired updates database is missing, please generate with:"
    echo "  $0 build-db"
    exit
  fi
}

xs_build_patches_db()
{
  local updates_xml_file
  local patch_id patch_url patch_time patch_uuid
  local xs_patch_prefix
  local updates_url

  case "${XS_RELEASE}" in
      "6.2") xs_patch_prefix="XS62";;
      "6.5") xs_patch_prefix="XS65";;
      "7.0") xs_patch_prefix="XS70";;
      "7.1") xs_patch_prefix="XS71";;
      "7.2") xs_patch_prefix="XS72";;
      *)
        echo "${XS_RELEASE} not yet managed"
        exit 1
        ;;
  esac

  if [ -z "${xs_patch_prefix}" ]; then
    echo "XS version required"
    exit 1
  fi

  updates_xml_file="updates.xml"
  updates_url="http://updates.xensource.com/XenServer/updates.xml"

  _title "Downloading ${updates_xml_file} from ${updates_url}"

  if ! curl -# -L -R -o "${updates_xml_file}" "${updates_url}"; then
    echo "cannot download patch"
    exit 1
  fi

  echo "extract linked patch list from ${updates_xml_file}"

  #Grep the patches for wanted version number, parse the data, and form the table
  #Columns are 1-patch name 2 - url 3- timestamp and 4- uuid
  #Each column is one variable and sorted by date and then by name

  # prune database file
  cat /dev/null > "${PATCHES_DATABASE}"
  xmllint --shell "${updates_xml_file}" <<< "cat //patch[contains(@name-label,'${xs_patch_prefix}')]/@name-label" | \
  grep -Ev ">|<| -" | \
  cut -d"\"" -f2 \
  | while read -r patch_id
        do
          echo "parsing data about '${patch_id}'"
          patch_url=$(xmllint -xpath "string(//patch[@name-label=\"${patch_id}\"]/@patch-url)" "${updates_xml_file}")
          patch_time=$(xmllint -xpath "string(//patch[@name-label=\"${patch_id}\"]/@timestamp)" "${updates_xml_file}")
          patch_uuid=$(xmllint -xpath "string(//patch[@name-label=\"${patch_id}\"]/@uuid)" "${updates_xml_file}")

         echo "${patch_id} ${patch_url} ${patch_time} ${patch_uuid}" >> "${PATCHES_DATABASE}"
  done

  echo "File ${PATCHES_DATABASE} generated"
}

# usage:
# xs_patch_exists "patch-id"
xs_patch_exists()
{
  local patch_id

  patch_id=$1
  _xe_command "${XE_CMD_PATCH_LIST} name-label=${patch_id} --minimal"

  if [ -n "${XE_RESPONSE}" ]; then
    echo "result:"
    echo "${XE_RESPONSE}"
    echo "> ${patch_id} is already uploaded to XenServer" >&2
    return 0
  else
    echo "> ${patch_id} not present on XenServer"
    return 1
  fi
}

# xs_patch_is_applied patch-uuid
xs_patch_is_applied()
{
  local patch_uuid
  local cmd

  patch_uuid=$1

  if [ -z "${patch_uuid}" ]; then
    echo "patch UUID not set"
    exit 1
  fi

  if [ "${POOL_APPLY}" == "yes" ]; then
    cmd="${XE_CMD_PATCH_LIST} params=hosts uuid=${patch_uuid} --minimal"
  else
    cmd="${XE_CMD_PATCH_LIST} params=hosts hosts:contains='${HOST_UUID}' uuid=${patch_uuid} --minimal"
  fi

  _xe_command "${cmd}"
  if [ -n "${XE_RESPONSE}" ]; then
    echo "result:"
    echo "${XE_RESPONSE}"
    echo "> patch ${patch_uuid} is already applied to XenServer" >&2
    return 0
  else
    echo "> patch ${patch_uuid} is not yet applied to XenServer" >&2
    return 1
  fi
}

xs_is_master()
{
  grep -q "^master$" /etc/xensource/pool.conf
}

xs_download_patches()
{
  check_updates_database

  _title "Downloading patches"

  if [ ! -d "${DOWNLOAD_DIR}" ]; then
    mkdir "${DOWNLOAD_DIR}"
  fi

  local short_url

  while read -r patch_id patch_url patch_time patch_uuid
  do
    echo -e "\\n>> ${patch_id}"
    # Check to see if the patch has been installed already
    if ! xs_patch_exists "${patch_id}"; then

      echo "> patch_url=${patch_url}"
      echo "> patch_time=${patch_time}"
      echo "> patch_uuid=${patch_uuid}"

      # check if download is required
      short_url="${DOWNLOAD_DIR}/${patch_url##*/}"
      if [ -f "${short_url}" ]; then
        echo "> ${short_url} already exists, skipping download"
      else
        echo "> Downloading ${short_url}"
        curl -# -o "${short_url}" -L -R "${patch_url}"
        echo -e "Download Completed"
      fi
      echo -e "> Unzipping ${short_url}"
      unzip -o -q "${short_url}"
    fi

  done < "${PATCHES_DATABASE}"

}

xs_upload_patches()
{
  local patch_id
  local patch_list

  check_updates_database
  _title "Uploading patches"

  mapfile -t patch_list <<< "$(awk -F ' ' '{print $1}' < "${PATCHES_DATABASE}")"
  echo "patch list:"
  echo "${patch_list[*]}"

  for patch_id in ${patch_list[*]}
  do
    echo -e "\\n>> ${patch_id}"
    xs_upload_patch "${patch_id}"
  done
}

# xs_upload_patch "patch-namelabel"
xs_upload_patch()
{
    local patch_id
    local patch_file

    patch_id=$1
    if ! xs_patch_exists "$patch_id"; then

      if [ -f "${patch_id}.iso" ]; then
        patch_file="${patch_id}.iso"
      elif [ -f "${patch_id}.xsupdate" ]; then
        patch_file="${patch_id}.xsupdate"
      else
        echo "no patch file found for ${patch_id}!" >&2
        exit 1
      fi

      echo "> uploading ${patch_file} to XenServer"
      if ! _xe_command "${XE_CMD_PATCH_UPLOAD} file-name=${patch_file}"; then
        echo "fail to upload!"
        echo "${XE_RESPONSE}"
        exit 1
      else
        rm "${patch_file}"
      fi
    fi
}

xs_apply_patches()
{
  check_updates_database

  _title "Applying patches"

  if [ -z "${POOL_APPLY}" ]; then
    help_die "POOL_APPLY must be set"
  fi

  if [ "${POOL_APPLY}" == "yes" ] && ! xs_is_master; then
      echo "This host is not a XenServer Pool Master, launch script with POOL_APPLY=no"
      exit 1
  fi

  echo "Pool apply mode ?: ${POOL_APPLY}"

  local xe_patch_cmd
  while read -r patch_id patch_url patch_time patch_uuid
  do
    echo ">> applying ${patch_id}"
    echo "> patch_uuid=${patch_uuid}"
    if ! xs_patch_is_applied "${patch_uuid}"; then
      if [ "${POOL_APPLY}" == "yes" ]; then
        xe_patch_cmd="${XE_CMD_PATCH_POOL_APPLY} uuid=${patch_uuid}"
      else
        xe_patch_cmd="${XE_CMD_PATCH_APPLY} uuid=${patch_uuid} host-uuid=${HOST_UUID}"
      fi
      if ! _xe_command "${xe_patch_cmd}"; then
        echo "failed to apply patch:"
        echo "${XE_RESPONSE}"
        exit 1
      fi
    fi
  done < "${PATCHES_DATABASE}"

}

# grab a key's value from /etc/xensource-inventory
# usage:
# xs_get_inventory_key "AN_INVENTORY_KEY"
xs_get_inventory_key()
{
  if [ -z "$1" ]; then
    echo "xs_get_inventory_key() requires an argument"
    exit 1
  fi
  local xs_inventory_key=$1
  local xs_inventory_value
  xs_inventory_value=$(grep "${xs_inventory_key}" /etc/xensource-inventory | cut -d '=' -f2)
  echo "${xs_inventory_value//\'}"
}

xs_get_release()
{
  echo "* Detect XenServer release"
  XS_RELEASE=$(xs_get_inventory_key "PRODUCT_VERSION_TEXT_SHORT")
  XS_VER_MAJOR="${XS_RELEASE:0:1}"
  XS_VER_MINOR="${XS_RELEASE:2:1}"
  echo "> XS release: ${XS_RELEASE}"
  echo "> XS version major: ${XS_VER_MAJOR}"
  echo "> XS version minor: ${XS_VER_MINOR}"

  readonly XS_RELEASE XS_VER_MAJOR XS_VER_MINOR

}

xs_get_host_uuid()
{
  local hostname
  local installation_uuid control_domain_uuid
  local inventory_key uuid

  echo "* Detect current host's UUID"

  hostname=$(grep "^HOSTNAME=" /etc/sysconfig/network | awk -F '=' '{print $2}')
  installation_uuid=$(xs_get_inventory_key "INSTALLATION_UUID")
  control_domain_uuid=$(xs_get_inventory_key "CONTROL_DOMAIN_UUID")

  echo "> installation_uuid: ${installation_uuid}"
  echo "> control_domain_uuid: ${control_domain_uuid}"
  echo "> hostname: ${hostname}"

  # detect host's UUID from inventory uuids
  for inventory_key in installation_uuid control_domain_uuid
  do
    # dereference key to get value
    uuid="${!inventory_key}"
    _xe_command "host-list uuid=${uuid} --minimal"
    HOST_UUID="${XE_RESPONSE}"
    if [ -n "${XE_RESPONSE}" ]; then
      echo "${inventory_key}'s UUID match this host!"
      HOST_UUID="${XE_RESPONSE}"
      break
    fi
  done

  # should never happends
  if [ -z "${HOST_UUID}" ]; then
    # if the script goes here, there is a XenServer configuration problem
    echo "Can't detect UUID, trying from hostname"
    _xe_command "host-list hostname=${hostname} --minimal"
    if [ -n "${XE_RESPONSE}" ]; then
      HOST_UUID="${XE_RESPONSE}"
    else
      echo "No way to get host UUID, stop!"
      exit 1
    fi
  fi

  echo "> current host UUID:${HOST_UUID}"
  readonly HOST_UUID
}

help_die()
{
  if [ -n "$1" ]; then
    echo -e "\\033[1;31mERROR: $1\\e[0m"
  fi

  cat <<EOF
Usage:
$0 [action]

action:
  apply    : apply uploaded updates
  build-db : grab all XenServer updates list from Citrix updates.xml
  download : download updates
  help     : this help
  upload   : upload updates to XenServer
  version  : print script version and exit

if you want to apply updates to a whole XenServer Pool, execute this from the master node:
  POOL_APPLY=yes $0 apply
otherwise:
  POOL_APPLY=no $0 apply

if you want to print executed XE command, set DEBUG=yes before the script
EOF
exit
}

#### main process ####

SOURCE="${BASH_SOURCE[0]}"
readonly BASE_DIR=$( cd -P "$( dirname "${SOURCE}" )" && pwd )
readonly PATCHES_DATABASE="${BASE_DIR}/patchList.db"
readonly DOWNLOAD_DIR="${BASE_DIR}/download"

ACTION=$1

case "${ACTION}" in
  apply)
    ACTION_FUNC="xs_apply_patches"
    ;;
  build-db)
    ACTION_FUNC="xs_build_patches_db"
    ;;
  download)
    ACTION_FUNC="xs_download_patches"
    ;;
  upload)
    ACTION_FUNC="xs_upload_patches"
    ;;
  version)
    echo "${VERSION}"
    exit 0
    ;;
  help|*)
    [ "${ACTION}" == "help" ] && ACTION=
    help_die "action '${ACTION}' is invalid"
    ;;
esac
shift

# Ensure we're running on a XenServer host
if ! XE_BIN=$(command -v xe); then
  echo "command 'xe' not found, this is not a XenServer host!"
  exit 1
else
  echo "xe found: ${XE_BIN}"
  readonly XE_BIN
fi

if [ ! -f "/etc/xensource-inventory" ]; then
  echo "/etc/xensource-inventory not found, this is not a XenServer host!"
  exit 1
fi

xs_get_release
xs_get_host_uuid

## select commands following XenServer release
# shellcheck disable=SC2086
if [ ${XS_VER_MAJOR} -ge 7 ] && [ ${XS_VER_MINOR} -ge 1 ]; then
  XE_CMD_PATCH_UPLOAD="update-upload"
  XE_CMD_PATCH_LIST="update-list"
  XE_CMD_PATCH_APPLY="update-apply"
  XE_CMD_PATCH_POOL_APPLY="update-pool-apply"
else
  XE_CMD_PATCH_UPLOAD="patch-upload"
  XE_CMD_PATCH_LIST="patch-list"
  XE_CMD_PATCH_APPLY="patch-apply"
  XE_CMD_PATCH_POOL_APPLY="patch-pool-apply"
fi

# command to execute determined by user input
if [ -n "${ACTION_FUNC}" ]; then
  ${ACTION_FUNC}
fi
