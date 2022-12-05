FROM fedora:31

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
    dnf -y remove gnome-tour && \
    dnf clean all

# systemd-logind refuses to start unless these lines are commented out
RUN sed -i /lib/systemd/system/systemd-logind.service \
    -e '/PrivateTmp=/s/^/#/g' \
    -e '/ProtectControlGroups=/s/^/#/g' \
    -e '/ProtectHome=/s/^/#/g' \
    -e '/ProtectKernelModules=/s/^/#/g' \
    -e '/ProtectSystem=/s/^/#/g' \
    -e '/ReadWritePaths=/s/^/#/g'

CMD gnome-session
