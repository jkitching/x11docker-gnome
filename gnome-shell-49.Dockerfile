FROM fedora:43

# Enable COPR repository for GNOME X11 support
RUN dnf -y copr enable frantisekz/GNOME-X11

RUN dnf -y update && \
    dnf -y install \
        xorg-x11-xinit \
        gnome-session-xsession \
        gnome-classic-session-xsession \
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
# Replace bwrap with a simple wrapper that executes commands without sandboxing
RUN mv /usr/sbin/bwrap /usr/sbin/bwrap.real && \
    cat > /usr/sbin/bwrap << 'EOF' && chmod +x /usr/sbin/bwrap
#!/bin/bash
# Wrapper to bypass bubblewrap sandboxing in containers
# Find the actual command to execute by parsing bwrap arguments
while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
        --ro-bind|--bind|--dev-bind|--ro-bind-try|--bind-try|--dev-bind-try|--symlink|--setenv)
            # These take 2 arguments
            shift; shift; shift
            ;;
        --tmpfs|--dir|--unsetenv|--chdir|--uid|--gid|--hostname|--sync-fd|--block-fd|--info-fd|--json-status-fd|--seccomp|--exec-label|--file-label|--dev|--proc)
            # These take 1 argument
            shift; shift
            ;;
        --unshare-all|--die-with-parent|--clearenv|--new-session|--as-pid-1|--cap-add|--cap-drop)
            # These take no arguments
            shift
            ;;
        --*)
            # Unknown flag, assume no arguments
            shift
            ;;
        *)
            # Found the command - everything from here is the command and its args
            exec "$@"
            exit 127
            ;;
    esac
done
# If we get here, no command was found
exit 1
EOF

# Workaround for gnome-extensions-app SIGILL crash - use software rendering
RUN mv /usr/bin/gnome-extensions-app /usr/bin/gnome-extensions-app.real && \
    cat > /usr/local/bin/gnome-extensions-app-wrapper << 'EOF' && \
    chmod +x /usr/local/bin/gnome-extensions-app-wrapper && \
    ln -s /usr/local/bin/gnome-extensions-app-wrapper /usr/bin/gnome-extensions-app
#!/bin/sh
GSK_RENDERER=cairo LIBGL_ALWAYS_SOFTWARE=1 exec /usr/bin/gnome-extensions-app.real "$@"
EOF

# Stop showing "Authentication Required to Create Managed Color Device":
# http://c-nergy.be/blog/?p=12073
RUN echo $'[Allow Colord all Users]\n\
Identity=unix-user:*\n\
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile\n\
ResultAny=no\n\
ResultInactive=no\n\
ResultActive=yes' > /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla

CMD ["gnome-session"]
