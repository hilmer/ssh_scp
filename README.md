ssh_scp
=======
ssh_scp is a client scp module for Erlang.

It can copy files and directory structures and follow symlinks.
It also allows you to send binary content as a file to the remote side as a file (did that sentence make sense)

Compile
-------
This module uses rebar, so `rebar compile`, does the trick.

Examples
--------
This library requires you to have allready established a connection using the ssh module.

All examples here copy to the destination "/tmp"

to copy a local file or directory:
```erlang
ok = ssh_scp:to(ConnectionRef, "local_dir_or_file","/tmp"),
```

You can set a few options defined  in ssh_scp_opts.hrl, for example you can set the atime or mtime to something different from the file you are copying like this:
```erlang
ok = ssh_scp:to(ConnectionRef, "local_dir_or_file","/tmp",#ssh_scp_opts{atime=1234555,mtime=5777777}),
```

or the timeout (in msec) for establishing a ssh channel for the transfer
```erlang
ok = ssh_scp:to(ConnectionRef, "local_dir_or_file","/tmp",#ssh_scp_opts{timeout=60000}),
```

To transfer a binary as a new file you us the to_file function
```erlang
%%Content is the binary
ok = ssh_scp:to_file(ConnectionRef, "filename", "/tmp",Content),
```

This will use the filepermission 0640 on the remote side, to specify the permission you can do either:
```erlang
%%Content is the binary
ok = ssh_scp:to_file(ConnectionRef, "filename", "/tmp",Content,"0666"),
```
or:
```erlang
%%Content is the binary
ok = ssh_scp:to_file(ConnectionRef, "filename", "/tmp",Content,#ssh_scp_opts{mode=438}),
```

A convenience function exists for specifying timeout and permission as a string
```erlang
%%Content is the binary
ok = ssh_scp:to_file(ConnectionRef, "filename", "/tmp",Content,40000, "0644"),
```

You can also specify atime, mtime and timeout options for to_file.


Note: It is not possible to change the file permission on a local file/directory transfer. 
Specifying mode in the options are ignored.


Testing
-------
Place a file called localhost_connection.hrl in the main directory, this file should contain options allowing to connect to your localhost ssh server and allow to write to /tmp directory. An example is provided in the file test_setup/localhost_connection.hrl
Read the documentation of the [Erlang ssh module connect method][http://www.erlang.org/doc/man/ssh.html#connect-3], to get the complete possible set of options for ssh connections.
Then just do `rebar compile eunit` to run the tests

License
-------
A license implies that I as the author intend to sue you or whatever for any use not covered by such license.
I have no intention of doing any such thing, so this software is released into the public domain, do what what you like with it.

Todo
----
1. receive from remote