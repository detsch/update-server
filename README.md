# Foundries Update Server
The update server is an open source system for managing Foundries.io update agents.
There are two primary use cases for this project:

 * Offline (air-gapped) environments where devices can't reach the Foundries.io backend
 * Users who want to manage their own device management solution

This project handles both use cases by implementing all the APIs used by Foundries.io update agents.
The project also includes a user-facing REST API and Web UI for managing devices and updates.

## Features

 * mTLS "device gateway" that supports Foundries.io update agents [aktualizr-lite](https://github.com/foundriesio/aktualizr-lite) and [fioup](https://github.com/foundriesio/fioup)
 * Device registration API compatible with [fio-device-register](https://github.com/foundriesio/lmp-device-register) and fioup.
 * Configuration management and remote actions compatible with [fioconfig](https://github.com/foundriesio/fioconfig)
 * Updates managed and signed using The Update Framework (TUF)
 * Pluggable authentication framework supporting:
   - Github SSO
   - Google SSO
   - Locally managed users
 * REST [API](./docs/api.md)
 * Web UI and command line tooling

The whole project runs in a single Golang process and uses SQLite to ensure 
admininstration and operation of the service is as easy as possible while
still scaling to the needs of non-hyperscalers.

## Quick start
Follow the [Quick Start](./docs/quick-start.md) guide to get a server running in development mode.

The server runs a complete web interface as well as command line tool, [fiocli](./docs/fiocli.md).

## Migrating from FoundriesFactory

If you have an existing Factory with provisioned devices, the [migration
guide](./docs/migration.md) covers signing with your Factory PKI, importing your
fleet's TUF root, and repointing devices at this server.

## Adding updates
The update server uses a content format compatible with [Offline Updates](https://docs.foundries.io/96/user-guide/offline-update/offline-update.html)
to serve devices their TUF, OSTree, and Container data. Before uploading,
see [How to build an Update](./docs/build-an-update.md) for producing that
content in the first place. Then follow the
[updates](./docs/updates.md) guide for setting this up.

## The Update Framework (TUF)
The update server uses TUF to secure the delivery of update manifests. See
[How TUF Works](./docs/tuf.md) for details.

## API access
Follow the [API](./docs/api.md) to learn how to access and use the REST API.

## Configuring authentication options
Follow the [configuring authentication](./docs/auth.md) guide for chosing the
method that meets your requirements.

## Branding and white-labeling
Follow the [branding guide](./docs/branding.md) to replace the server's default
look with your own logo, favicon, and color scheme — no rebuild required.

## Running in production
The [production guide](./docs/production.md) covers considerations when
deploying the update server for production use.

## Advanced topics

The [advanced topics guide](./docs/advanced.md) covers custom listen
addresses, certificate lifetimes, and manual device registration.

## Developing
The project is a single Golang binary that can be built with:
```
 go build -o fioserver github.com/foundriesio/update-server/cmd/server
```

A "devshell" is also included that can be used for local development:
```
 ./contrib/dev-shell
```

***NOTE***: This repository uses Git-LFS. You'll need this installed to use the web UI.

## License
*update-server* is under the [BSD 3-Clause Clear](./LICENSE.txt) license.
