# MeshGhost

MeshGhost is a visual-only multiplayer layer for single-player games. Each player runs a fully independent copy of the game, and remote players are rendered as cosmetic ghosts with no shared world state.

Key ideas:

- Relay server is game-agnostic
- Core client is game-agnostic
- Adapter contract is intentionally thin
- Game-specific adapters are rewritten per game

See `Ghostsync brief.md` for the design vision and `agent_docs/plans.md` for the current roadmap.

tl;dr

Server/relay:
just passes messages between players
does not run the game

Client:
the part that connects to the relay and handles the network side
sends your state, receives the other player’s state

Adapter:
the game-specific layer
this is the “mod” or integration layer that talks to the actual game
it reads the game’s state and draws the ghost

//

I want the project to feel simple and easy for end users. The goal is that someone can download the mod/adapter for their game, run the server and client, and start playing without needing to install Python, runtime tools, or other dependencies. The main application should be packaged as a normal desktop program that works on Windows, Linux, and macOS, while the game-specific adapter/mod remains lightweight and easy to drop in.

project structure ideas, to seperate unpacked dev files from packaged/intended for the user

MeshGhost/
├── README.md
├── LICENSE
├── releases/
│   ├── windows/
│   ├── linux/
│   └── mac/
├── adapters/
│   └── emerald/
│       └── ...
├── dev/
│   ├── client/
│   ├── server/
│   ├── core/
│   ├── docs/
│   └── tests/
└── docs/

-

MeshGhost/
├── README.md
├── releases/
├── adapters/
└── dev/
