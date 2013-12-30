-record(ssh_scp_opts,
        {
         timeout :: non_neg_integer(),  %channel timeout
         atime   ::  non_neg_integer(), % atime in unix epochs()
         mtime   ::  non_neg_integer(), %  mtime in unix epochs()
         mode    :: non_neg_integer()   % File permission
        }).

