
protocols = [
    'fractional-scale-v1',
    'idle-inhibit-unstable-v1',
    'keyboard-shortcuts-inhibit-unstable-v1',
    'pointer-constraints-unstable-v1',
    'primary-selection-unstable-v1',
    'relative-pointer-unstable-v1',
    'tablet-unstable-v2',
    'text-input-unstable-v3',
    'viewporter',
    'wayland',
    'xdg-activation-v1',
    'xdg-decoration-unstable-v1',
    'xdg-output-unstable-v1',
    'xdg-shell',
]

if wayland_scanner.found() and wayland_found
    foreach proto : protocols
        proto_xml = '@0@.xml'.format(proto)
        proto_c = '@0@-protocol.c'.format(proto)
        proto_h = '@0@-client-protocol.h'.format(proto)

        c_sources += custom_target(proto_c,
            command : [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@'],
            input : proto_xml,
            output : proto_c,
        )

        c_sources += custom_target(proto_h,
            command : [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@'],
            input : proto_xml,
            output : proto_h,
        )
    endforeach

    core_inc += include_directories('.')
endif
