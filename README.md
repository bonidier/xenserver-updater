# xenserver-updater

xenserver-updater is Bash tool to easily download and apply updates for XenServer

Only Tested on XenServer 7.2 for now, but should work from 6.0 to 7.2

**inspired by:**

- https://github.com/patones/XenServer-Patcher-bash/
- https://github.com/dalgibbard/citrix_xenserver_patcher/

## Requirements

Copy `xs-updater.sh` to your XenServer on root account

## Usage

### Embedded help

    Usage:
    ./xs-updater.sh [action]

    action:
      apply    : apply uploaded updates
      build-db : grab all XenServer updates list from Citrix updates.xml
      download : download updates
      help     : this help
      upload   : upload updates to XenServer
      version  : print script version and exit

    if you want to apply updates to a whole XenServer Pool, execute this from the master node:
      POOL_APPLY=yes ./xs-updater.sh apply
    otherwise:
      POOL_APPLY=no ./xs-updater.sh apply

    if you want to print executed XE command, set DEBUG=yes before the script

### Steps

**Generate updates database for the current XS release**

    ./xs-updater.sh build-db

**Download updates for current XS release**

  ./xs-updater.sh download

**Upload updates to XenServer**

  ./xs-updater.sh upload

**Apply updates**

if you want to apply updates to a whole XenServer Pool, execute this from the master node:

  POOL_APPLY=yes ./xs-updater.sh apply

otherwise:

  POOL_APPLY=no ./xs-updater.sh apply

### Debug

if you want to print executed XE command, set DEBUG=yes before the script

**sample**

    DEBUG=yes ./xs-updater.sh upload
