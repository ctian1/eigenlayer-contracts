import "hardhat-preprocessor";
import fs from "fs";
import "solidity-docgen";
import '@openzeppelin/hardhat-upgrades';
import "dotenv/config";

function getRemappings() {
  return fs
    .readFileSync("remappings.txt", "utf8")
    .split("\n")
    .filter(Boolean) // remove empty lines
    .map((line) => line.trim().split("="));
}

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.12",
  preprocess: {
    eachLine: (hre) => ({
      transform: (line: string) => {
        if (line.match(/^\s*import /i)) {
          for (const [from, to] of getRemappings()) {
            if (line.includes(from)) {
              line = line.replace(from, to);
              break;
            }
          }
        }
        return line;
      },
    }),
  },
  networks: {
    mainnet: {
      url: process.env.RPC_MAINNET!,
      gas: "auto",
    },
    goerli: {
      url: process.env.RPC_GOERLI!,
      gas: "auto",
    },
  },
  paths: {
    sources: "./src/contracts",
    // cache: "./cache_hardhat",
  },
  docgen: {
    outputDir: "docs/docgen",
    pages: "files"
  }
};
