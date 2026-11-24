// Settings for /agent-id. Mirrors skills/haptix/config.json.
window.HAPTIX_AGENT_ID = {
  chainId: 56,
  chainName: "BNB Chain",
  rpcUrl: "https://bsc-dataseed1.bnbchain.org",
  registry: "0xF2aD0c1fD648A4a556872456ce5BBCE97E9e8e1f",
  vault: "0x01Cf3189f7a681073081b3Fca520512EB67E26Ca",
  badge: "0xD88e147C02f4E0eD93A67d043Ef31AC4DDbf253A",
  explorer: "https://bscscan.com",
  // Mirrors skills/haptix/config.json "starterGuard": one preset every holder can open.
  starterGuard: {"token": "0x55d398326f99059fF775485246999027B3197955", "daily": "5", "ceiling": "2", "passkeyAbove": "2", "delay": "24h"},
  agentIdClaimPath: "Binance App → Wallet → Agent ID banner",
  announcementUrl: "https://www.binance.com/en/support/announcement/detail/95f5dbe0ea674a48a739b59e046648bf",
  repo: "https://github.com/ritesh59697/haptix-agent-os",
  skillPath: "ritesh59697/haptix-agent-os/skills/haptix",
  binanceSkillPath: "binance/binance-skills-hub/skills/binance-web3/binance-agentic-wallet",
  // Function selectors live in /haptix-abi.json, generated from the compiled
  // contracts by scripts/gen-skill-abi.sh.
  abiUrl: "/haptix-abi.json",
};
