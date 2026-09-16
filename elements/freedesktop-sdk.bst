kind: junction

sources:
- kind: git_repo
  url: gitlab:freedesktop-sdk/freedesktop-sdk.git
  track: freedesktop-sdk-25.08*
# renovate: datasource=git-refs depName=https://gitlab.com/freedesktop-sdk/freedesktop-sdk.git
  ref: freedesktop-sdk-25.08.16-0-gc4f8b7234c787e8282fb9d4f208b08f9f677eba9

config:
  options:
    target_arch: '%{arch}'

  overrides:
    components/systemd-base.bst: gnome-build-meta.bst:core-deps/systemd-base.bst
    components/systemd.bst: gnome-build-meta.bst:core-deps/systemd.bst
    components/systemd-ukify.bst: gnome-build-meta.bst:core-deps/systemd-ukify.bst
    components/systemd-libs.bst: gnome-build-meta.bst:core-deps/systemd-libs.bst

    components/geoclue-base.bst: gnome-build-meta.bst:gnomeos-deps/geoclue-base.bst
