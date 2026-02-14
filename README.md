## YTDLnis Packages

# General information

This repository is built for storage and documentation purposes.
Each package is a shell app that simply contains jniLibs within them. YTDLnis can then access them based on their package name to import the zip into its own file system to execute them.
This method also bypasses the SDK28 restriction, that restricts executing executables that are not pre-bundled within the app in jniLibs folder.

By using helper apks, the libxxx.so is extracted from jniLibs from the helper apk and its usable to any app in the device as long as you know the package name.
libxxx.so is a just a binary that executes contents in libxxx.zip.so
libxxx.zip.so can be read by other apps as long as you know the package name, so you can copy and unzip its contents to the app's filesystem.
Then you can make helper apk's libxxx.so execute the extracted zip containing the usr/ files. 

You could also inject the jniLibs files directly in the app without apk helpers, but you have to downgrade to target sdk28 to achieve this.

Building termux-packages takes an excessive amount of time, and github workflows has a time limit, so it is impossible to build it within github, so i am building the packages locally and then manually publishing new versions

# To build jniLibs locally

- clone latest version of termux-packages repo
- pull the latest version of termux/package-builder docker image
- put either script inside termux-packages folder
- execute:
```
./scripts/run-docker.sh ./clean
./scripts/run-docker.sh ./myscript.sh
```