FROM fedora:26

# gnome-extensions-app package does not exist;
# use gnome-shell-extension-prefs bundled in gnome-shell instead
RUN dnf -y update && \
    dnf -y install \
        @base-x \
        dbus-x11 \
        gnome-session \
        gnome-shell \
        gnome-terminal \
        nautilus \
        mesa-dri-drivers \
        mesa-libGL \
        && \
    dnf clean all

CMD gnome-session
