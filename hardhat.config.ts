import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

const config: HardhatUserConfig = {
	solidity: {
		version: "0.8.23",
		settings: {
			optimizer: {
				enabled: true,
				runs: 2000,
			},
		},
	},
};

export default config;
