# Security policy

Report security vulnerabilities privately through
[GitHub vulnerability reporting](https://github.com/justusperillieux/neorex/security/advisories/new).
Include the Neorex commit, Rex and Neovim versions, operating system, reproduction
steps and relevant errors with private information removed.

Supported fixes target the current Lua plugin on `main`.

Neorex stores its editor sockets and state in private per-user directories.
Reports about access to those sockets, unsafe file operations, terminal input,
or disclosure of local review comments and transcript data are in scope.
Rex configuration and Neovim plugins run as trusted code with the user's privileges.
