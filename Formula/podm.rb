# SPDX-License-Identifier: Apache-2.0
# Copyright © 2026 the podm authors.
#
# Ready and waiting for the first tagged release: the release pipeline
# publishes this formula to the kaovilai/homebrew-tap repository, after which
# `brew install kaovilai/tap/podm` works. The URL/sha256 below are updated
# automatically at release time.

class Podm < Formula
  desc "Run the stock podman/docker CLIs natively on macOS over Apple containerization"
  homepage "https://github.com/kaovilai/podm"
  # TODO: at first release, point this at the real tag and replace the sha256
  # with the real checksum of the tarball (shasum -a 256 of the downloaded
  # archive, or `brew fetch --build-from-source <url>`).
  url "https://github.com/kaovilai/podm/archive/refs/tags/v0.0.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  version "0.0.0-dev"
  license "Apache-2.0"

  # Same toolchain floor as Apple's own `container` formula (homebrew-core):
  # Swift 6.2 ships with Xcode 26, and the Apple containerization frameworks
  # underneath podm require macOS 26 (Tahoe) on Apple Silicon.
  depends_on xcode: ["26.0", :build]
  depends_on arch: :arm64
  depends_on macos: :tahoe
  depends_on "container"

  def install
    # BuildInfo embeds these at compile time; podmd --version reports them.
    ENV["BUILD_VERSION"] = version
    ENV["BUILD_TIME"] = Time.now.utc.to_s

    # std_swift_args passes --disable-sandbox (SPM fetches dependencies over
    # the network, which Homebrew's build sandbox blocks) plus release config.
    system "swift", "build", *std_swift_args

    release_dir = buildpath/".build/release"
    libexec.install release_dir/"podmd"
    libexec.install release_dir/"podm"
    bin.install_symlink libexec/"podmd" => "podmd"
    bin.install_symlink libexec/"podm" => "podm"
  end

  def caveats
    <<~EOS
      podm wraps the real podman/docker CLIs — they are not bundled with this
      formula. Install the personas you want, then record them once:

        brew install podman docker
        podm install

      `podm install` creates podm/podman/docker shims in ~/.podm/bin and
      records the real CLI paths for fast, PATH-order-independent lookup. Put
      the shim directory on your PATH (e.g. in ~/.zshrc):

        export PATH="$HOME/.podm/bin:$PATH"

      Apple's container runtime (the `container` formula) is installed as a
      dependency of this formula. Do not run `podman machine` — podm manages
      containers natively over Apple containerization, no VM and no remote
      connection setup is needed.
    EOS
  end

  test do
    # podmd --version exits before binding any socket or starting Vapor.
    assert_match version.to_s, shell_output("#{bin}/podmd --version")
  end
end
