## YTDLNIS PLUGINS

To build locally

- clone latest version of termux-packages repo
- pull the latest version of termux/package-builder docker image
- put either script inside termux-packages folder
- execute:
```
./scripts/run-docker.sh ./clean
./scripts/run-docker.sh ./myscript.sh
```