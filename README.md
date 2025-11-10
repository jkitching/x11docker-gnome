# x11docker-gnome

A collection of Dockerfiles for building images with different versions of GNOME.  These images can then be run with [x11docker](https://github.com/mviereck/x11docker).  Fedora images are used as a base, since versions of Fedora conveniently correspond to each stable version of GNOME.

![Running multiple containers of different GNOME versions](gnome-containers.png)

`Makefile` allows building, pushing, pulling, and running of each image.  (Running in this case is just invoking `/bin/bash`---for starting with x11docker, see `run-gnome-desktop.sh`.)

The recommended workflow is as follows:

```sh
# Pull images from Docker Hub:
#   docker.io/jkitching/gnome-shell-XYZ
make pull gnome-shell-39 gnome-shell-40  # pull individual images
make pull all                            # pull all images

# Copy the run shell script template
cp run-gnome-desktop.sh.template run-gnome-desktop.sh
chmod +x run-gnome-desktop.sh

# Make modifications as necessary
vim run-gnome-desktop.sh

# Start GNOME container with x11docker
./run-gnome-desktop.sh gnome-shell-39
```

For more details on how it all works, check out this blog post: [GNOME development with x11docker containers](https://joelkitching.com/gnome-development-with-x11docker-containers/).

## Included packages

* **gnome-terminal**
* **gnome-extensions-app** (separate package from GNOME 3.36 onward)
* **nautilus** for file browsing
* **xdg-user-dirs** creates directories required for taking screenshots
* **mesa-dri-drivers** and **mesa-libGL** for GPU acceleration
* **Xephyr** for displaying GDM login screen
* **xdotool** and **wmctrl** for programmatically controlling X11
* **iproute** for `ss` tool used to query TCP and other sockets (e.g. find open ports)
* **gnome-tour** is removed, because we don't want a tour
