{
  inputs.nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    inherit (nixpkgs) lib;
  in {
    # Default system
    defaultPackage.x86_64-linux = self.packages.x86_64-linux.ociImage;

    packages.x86_64-linux = let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;

      # FIXME: this would be the module system result producing RootFS.
      # Since I *cannot* be arsed to figure out a RootFS derivation right
      # now, this temporary placeholder will do.
      myRootFS = pkgs.stdenvNoCC.mkDerivation {
        name = "my-rootfs";
        buildInputs = [pkgs.busybox pkgs.coreutils pkgs.gnutar pkgs.openssl];
        buildCommand = ''
          mkdir -p $out
          # Copy your system closure into $out
          # For testing/demonstration purposes only, I'll just provide a very
          # minimal bin/sh
          mkdir -p $out/bin
          ln -s ${pkgs.busybox}/bin/sh $out/bin/sh
          mkdir -p $out/etc
          echo "root:x:0:0:root:/root:/bin/sh" > $out/etc/passwd
        '';
      };

      # A non-standard OCI image builder that we can bootstrap with little to
      # no external dependencies. In the case of Snugnug/MicrOS, this might
      # make bootstrapping faster and cheaper. If C stdlib could write JSON
      # *reliably* I might've done this in C tbh.
      # TODO: maybe we can write JSON files with Nix and simply move them
      # over?
      # TODO: add something for the tag attribute
      buildOCIImage = {
        rootfs,
        cmd ? ["/bin/sh"],
        imageName ? "myimage",
        arch ? "amd64",
      }:
        pkgs.stdenvNoCC.mkDerivation {
          name = "${imageName}-oci";
          buildInputs = [pkgs.gnutar pkgs.coreutils];
          buildCommand = ''
            mkdir -p $out/blobs/sha256

            # Tar the rootfs. Feathers come later.
            tar --sort=name --numeric-owner --owner=0 --group=0 --mtime='UTC 2020-01-01' \
              -C ${rootfs} -cf layer.tar .
            LAYER_SHA=$(sha256sum layer.tar | cut -d' ' -f1)
            mv layer.tar $out/blobs/sha256/$LAYER_SHA

            # Config blob
            cat > config.json <<EOF
            {
              "architecture": "${arch}",
              "os": "linux",
              "rootfs": { "type": "layers", "diff_ids": ["sha256:$LAYER_SHA"] },
              "config": { "Cmd": [${lib.concatStringsSep ", " (map (c: "\"${c}\"") cmd)}] }
            }
            EOF

            CFG_SHA=$(sha256sum config.json | cut -d' ' -f1)
            cp config.json $out/blobs/sha256/$CFG_SHA

            # Manifest
            cat > manifest.json <<EOF
            {
              "schemaVersion": 2,
              "config": { "mediaType": "application/vnd.oci.image.config.v1+json", "digest": "sha256:$CFG_SHA", "size": $(stat -c%s config.json) },
              "layers": [
                { "mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": "sha256:$LAYER_SHA", "size": $(stat -c%s $out/blobs/sha256/$LAYER_SHA) }
              ]
            }
            EOF
            M_SHA=$(sha256sum manifest.json | cut -d' ' -f1)
            cp manifest.json $out/blobs/sha256/$M_SHA

            # Index
            cat > $out/index.json <<EOF
            {
              "schemaVersion": 2,
              "manifests": [
                { "mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": "sha256:$M_SHA", "size": $(stat -c%s manifest.json) }
              ]
            }
            EOF
          '';
        };

      # Produce a docker-archive tarball for "docker load"
      exportDockerArchive = ociImage:
        pkgs.runCommandNoCC "docker-archive.tar" {buildInputs = [pkgs.gnutar pkgs.coreutils];} ''
          mkdir work
          cp -r ${ociImage} work/oci

          # Extract digest shas
          CFG_SHA=$(jq -r '.config.digest' work/oci/manifest.json | cut -d: -f2)
          LAYER_SHA=$(jq -r '.layers[0].digest' work/oci/manifest.json | cut -d: -f2)

          mkdir -p work/docker
          cp work/oci/blobs/sha256/$CFG_SHA work/docker/$CFG_SHA.json
          cp work/oci/blobs/sha256/$LAYER_SHA work/docker/layer.tar

          # docker manifest
          cat > work/docker/manifest.json <<EOF
          [
            {
              "Config": "$CFG_SHA.json",
              "RepoTags": ["myimage:latest"],
              "Layers": ["layer.tar"]
            }
          ]
          EOF

          # Repositories file
          cat > work/docker/repositories <<EOF
          {"myimage":{"latest":"$CFG_SHA"}}
          EOF

          tar -C work/docker -cf $out .
        '';
    in {
      ociImage = buildOCIImage {
        rootfs = myRootFS;
        cmd = ["/bin/sh"];
      };

      dockerArchive = exportDockerArchive (self.packages.x86_64-linux.ociImage);
    };
  };
}
