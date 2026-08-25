# Fiocli

The Update Server includes a command line interface, fiocli. Each
[release](https://github.com/foundriesio/update-server/releases) includes
a statically compiled binary for many operating systems.

## Building
Fiocli can be built from source with `make fiocli`. The resulting file will be
under `bin/fiocli-<os>-<cpu>`.

It can also be built for a range of operating systems and CPUs.

## Configuration
Before you can use the CLI, you must login to an Update Server with:
```
 # fiocli login <context-name> <server>
 fiocli login localdev http://localhost:8080
```
The context-name allows you to be logged into multiple update servers.
The login command will set this to your default context so that all
fiocli commands will target this server.

The default configuration file is located under `${HOME}/.config/fiocli.yaml`.

## Contexts
If you are logged into multiple servers, you may target them by context
name by including `--context=<context>` in your commands. For example:
```
 fiocli --context=server1 devices list   # list devices on update server 1
 fiocli --context=server2 devices list   # list devices on update server 2
```