# SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
# SPDX-License-Identifier: LicenseRef-DCL-1.0
{
  description = "Ownership and access-control tooling for Raindex orders and vaults.";

  inputs = {
    rainix.url = "github:rainlanguage/rainix";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      flake-utils,
      rainix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = rainix.pkgs.${system};
      in
      rec {
        packages = rainix.packages.${system};

        devShells.default = pkgs.mkShell {
          inherit (rainix.devShells.${system}.default) shellHook;
          packages = [ ];
          inputsFrom = [ rainix.devShells.${system}.default ];
        };
      }
    );
}
