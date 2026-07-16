# syntax=docker/dockerfile:1.4
# docker.io/library/fedora has no 44 tag: Fedora publishes official container
# images to quay.io as of 44.
FROM quay.io/fedora/fedora:44

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
        adwaita-icon-theme \
        hicolor-icon-theme \
        gdk-pixbuf2 \
        glycin-loaders \
        glycin-gtk4-libs \
        shared-mime-info \
        librsvg2 \
        && \
    dnf -y remove gnome-tour && \
    dnf clean all

# Update pixbuf loaders cache and icon cache
RUN gdk-pixbuf-query-loaders-64 --update-cache && \
    gtk4-update-icon-cache -f /usr/share/icons/hicolor/ 2>/dev/null || true && \
    gtk4-update-icon-cache -f /usr/share/icons/Adwaita/ 2>/dev/null || true

# Workaround: Glycin loaders require bubblewrap sandboxing which doesn't work in containers
RUN mv /usr/sbin/bwrap /usr/sbin/bwrap.real
RUN cat > /usr/sbin/bwrap <<'EOF'
#!/bin/bash
# Bypass bubblewrap sandboxing in containers: parse args, exec the actual command
while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
        --ro-bind|--bind|--dev-bind|--ro-bind-try|--bind-try|--dev-bind-try|--symlink|--setenv)
            shift; shift; shift
            ;;
        --tmpfs|--dir|--unsetenv|--chdir|--uid|--gid|--hostname|--sync-fd|--block-fd|--info-fd|--json-status-fd|--seccomp|--exec-label|--file-label|--dev|--proc)
            shift; shift
            ;;
        --unshare-all|--die-with-parent|--clearenv|--new-session|--as-pid-1|--cap-add|--cap-drop)
            shift
            ;;
        --*)
            shift
            ;;
        *)
            exec "$@"
            exit 127
            ;;
    esac
done
exit 1
EOF
RUN chmod +x /usr/sbin/bwrap

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
