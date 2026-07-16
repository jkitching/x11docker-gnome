# syntax=docker/dockerfile:1.4
FROM fedora:42

RUN echo -e '[main]\nmax_parallel_downloads=10\nfastestmirror=True' >> /etc/dnf/dnf.conf

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
        Xephyr \
        xorg-x11-server-Xvfb \
        xdotool \
        wmctrl \
        iproute \
        && \
    dnf -y remove gnome-tour && \
    dnf clean all

# Workaround for gnome-extensions-app SIGILL crash - use software rendering
RUN mv /usr/bin/gnome-extensions-app /usr/bin/gnome-extensions-app.real
COPY <<'EOF' /usr/local/bin/gnome-extensions-app-wrapper
#!/bin/sh
GSK_RENDERER=cairo LIBGL_ALWAYS_SOFTWARE=1 exec /usr/bin/gnome-extensions-app.real "$@"
EOF
RUN chmod +x /usr/local/bin/gnome-extensions-app-wrapper && \
    ln -sf /usr/local/bin/gnome-extensions-app-wrapper /usr/bin/gnome-extensions-app

# Stop showing "Authentication Required to Create Managed Color Device":
# http://c-nergy.be/blog/?p=12073
RUN echo $'[Allow Colord all Users]\n\
Identity=unix-user:*\n\
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile\n\
ResultAny=no\n\
ResultInactive=no\n\
ResultActive=yes' > /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla

CMD ["gnome-session"]

LABEL org.opencontainers.image.source="https://github.com/jkitching/x11docker-gnome"
