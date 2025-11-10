FROM fedora:28

# The gnome-extensions-app package does not exist in GNOME 3.34 and earlier;
# use gnome-shell-extension-prefs bundled in gnome-shell instead.
# Some GNOME functionality (e.g. taking screenshots) requires directories
# created by xdg-user-dirs.
RUN dnf -y update && \
    dnf -y install \
        @base-x \
        dbus-x11 \
        gnome-session \
        gnome-shell \
        gnome-terminal \
        nautilus \
        xdg-user-dirs \
        mesa-dri-drivers \
        mesa-libGL \
        Xephyr \
        xdotool \
        wmctrl \
        iproute \
        && \
    dnf clean all

# Stop showing "Authentication Required to Create Managed Color Device":
# http://c-nergy.be/blog/?p=12073
RUN echo $'[Allow Colord all Users]\n\
Identity=unix-user:*\n\
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile\n\
ResultAny=no\n\
ResultInactive=no\n\
ResultActive=yes' > /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla

CMD ["gnome-session"]
