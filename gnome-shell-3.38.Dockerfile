FROM fedora:33

RUN dnf -y update && \
    dnf -y install \
        @base-x \
        dbus-x11 \
        gnome-session \
        gnome-shell \
        gnome-terminal \
        gnome-extensions-app \
        nautilus \
        mesa-dri-drivers \
        mesa-libGL \
        && \
    dnf -y remove gnome-tour && \
    dnf clean all

CMD gnome-session
