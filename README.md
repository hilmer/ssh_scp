ssh_scp
=======
ssh_scp is a client scp module for Erlang.

It can copy files and directory structures and follow symlinks.
It also allows you to send binary content as a file to the remote side as a file (did that sentence make sense)

Compile
_______
This module uses rebar, so `rebar compile`, does the trick.

Examples
________
to copy a local file or directory

Testing
-------
Place a file called localhost_connection.hrl in the main directory, this file should contain options allowing to connect to your localhost ssh server and allow to write to /tmp directory. An example is provided in the file test_setup/localhost_connection.hrl
Read the documentation of the [Erlang ssh module connect method][http://www.erlang.org/doc/man/ssh.html#connect-3], to get the complete possible set of options for ssh connections.
Then just do `rebar compile eunit` to run the tests

License
_______
A license implies that I as the author intend to sue you or whatever for any use not covered by such license.
I have no intention of doing any such thing, so this software is released into the public domain, do what what you like with it.

Todo
____

1. receive from remote