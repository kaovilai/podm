# SPDX-License-Identifier: Apache-2.0
# Copyright © 2026 the pacman authors.
#
# NOTE: the pacman repository is currently private, so this formula is
# aspirational/ready — it only becomes installable (e.g. via a tap:
# `brew install kaovilai/pacman/pacman`) once the repository is public and the
# first release tag exists.

class Pacman < Formula
  desc "Run the stock podman/docker CLIs natively on macOS over Apple containerization"
  homepage "https://github.com/kaovilai/pacman"
  # TODO: at first release, point this at the real tag and replace the sha256
  # with the real checksum of the tarball (shasum -a 256 of the downloaded
  # archive, or `brew fetch --build-from-source <url>`).
  url "https://github.com/kaovilai/pacman/archive/refs/tags/v0.0.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  version "0.0.0-dev"
  license "Apache-2.0"

  # Same toolchain floor as Apple's own `container` formula (homebrew-core):
  # Swift 6.2 ships with Xcode 26, and the Apple containerization frameworks
  # underneath pacman require macOS 26 (Tahoe) on Apple Silicon.
  depends_on xcode: ["26.0", :build]
  depends_on arch: :arm64
  depends_on macos: :tahoe
  depends_on "container"

  def install
    # BuildInfo embeds these at compile time; pacmand --version reports them.
    ENV["BUILD_VERSION"] = version
    ENV["BUILD_TIME"] = Time.now.utc.to_s

    # std_swift_args passes --disable-sandbox (SPM fetches dependencies over
    # the network, which Homebrew's build sandbox blocks) plus release config.
    system "swift", "build", *std_swift_args

    release_dir = buildpath/".build/release"
    libexec.install release_dir/"pacmand"
    libexec.install release_dir/"pacman"
    bin.install_symlink libexec/"pacmand" => "pacmand"
    bin.install_symlink libexec/"pacman" => "pacman"
  end

  def caveats
    <<~EOS
      pacman wraps the real podman/docker CLIs — they are not bundled with this
      formula. Install the personas you want, then record them once:

        brew install podman docker
        pacman install

      `pacman install` creates pacman/podman/docker shims in ~/.pacman/bin and
      records the real CLI paths for fast, PATH-order-independent lookup. Put
      the shim directory on your PATH (e.g. in ~/.zshrc):

        export PATH="$HOME/.pacman/bin:$PATH"

      Apple's container runtime (the `container` formula) is installed as a
      dependency of this formula. Do not run `podman machine` — pacman manages
      containers natively over Apple containerization, no VM and no remote
      connection setup is needed.
    EOS
  end

  test do
    # pacmand --version exits before binding any socket or starting Vapor.
    assert_match version.to_s, shell_output("#{bin}/pacmand --version")
  end
end
