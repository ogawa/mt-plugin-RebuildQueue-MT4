Rebuild Queue
Version 1.04


Summary
=======

The Rebuild Queue plugin is designed to let you shift the rebuilding
operations typically done by Movable Type to one or more "offline"
processes.

With this plugin, you can fine-tune your building operations so they
are distributed and distribute the built pages across any number of
servers.


Requirements
============

Movable Type version 3.3 or later (or Movable Type Enterprise).

The 'rsync' command if using remote server synchronization. (see: http://samba.anu.edu.au/rsync/)

Time::HiRes (see: http://search.cpan.org/dist/Time-HiRes/)

Installation
============

To install, place the "RebuildQueue" directory in this distribution
underneath your Movable Type "plugins" directory. Once the files are
physically installed, accessing Movable Type will trigger an upgrade
procedure which will install the plugin's table into your database.

The plugin files, once installed should match that shown below:

    MT_DIR/
           mt-static/
                     RebuildQueue/
                                  rebuildq.gif
           plugins/
                   RebuildQueue/
                                lib/
                                    RebuildQueue/
                                                 Daemon.pm
                                                 File.pm
                                                 Plugin.pm
                                                 Publisher.pm
                                RebuildQueue.pl


All files should have permission that make them readable by the
web server and/or account being used to invoke the offline
RebuildQueue.pl script (644 permissions); the RebuildQueue.pl
script should be executable (755 permissions).

Once the installation is complete, you are ready to configure the
plugin.


Configuration
=============

Global Configuration Options
----------------------------

Navigate to the Plugin listing from the MT System Overview menu. There you
will find an entry for the Rebuild Queue plugin. Click the "Show Settings"
link to reveal the global configuration settings.

"Number of Workers": This setting lets you define how many rebuild "worker"
processes you plan to run. The default number is 1, but you can increase
this number if you wish. When the Rebuild Queue schedules a page to be
rebuilt, it can randomly assign the task to one of the worker processes. This
helps distribute the rebuilding load across multiple processes or servers.

Weblog Configuration Options
----------------------------

To enable the Rebuild Queue, you must go to the weblog(s) you wish it to
manage and enable it for each of them. From the Weblog Settings page, go
to the "Plugins" tab and click the "Show Settings" link for the Rebuild Queue
entry listed there. The following settings are available at the weblog level:

"Enable for this Weblog?": Check this option to enable the Rebuild Queue to
manage rebuilding for that weblog.

"Force Building to Worker": If you have configured (at the global level) 2
or more worker processes, you will see this option. It lets you assign any
queued build operations for this weblog to a particular worker. This gives
you control over which worker process builds the weblog instead of it being
randomly distributed.

Cron Jobs and Daemon Processes
------------------------------

Since rebuilding is done separately, it's important to set up the
Rebuild Queue processes to do the actual rebuilding operations and
mirroring you may require.

The RebuildQueue.pl script is used to run these processes. Running
RebuildQueue.pl without any options will show the command usage.

A typical cron job for the RebuildQueue itself might be something like this:

*/15 * * * * cd /path/to/RebuildQueue; ./RebuildQueue.pl

This will invoke the Rebuild Queue every 15 minutes to build any pages that
have been modified since the last execution. Of course, you can invoke it
more often than that if you prefer.

*/15 * * * * cd /path/to/RebuildQueue; ./RebuildQueue.pl -sync -to user@hostname:
 
This cron job will handle the rsync job to copy content from the local
server to another.

*/15 * * * * cd /path/to/RebuildQueue; ./RebuildQueue.pl -daemonize

This will invoke the Rebuild Queue process as a daemon; that is, it will
remain running until the process has been halted. This may be preferable
since it will see pending rebuild requests almost immediately and handle
them sooner. It only allows one daemon to run, so setting it up on a cron
job is a way to make sure the daemon process is always running, even if
it is killed for one reason or another.

*/15 * * * * cd /path/to/RebuildQueue; ./RebuildQueue.pl -daemonize -worker 2

This sets up a second worker daemon. I said only one daemon can run, but
that only applies by worker id (the default worker id is 1). So you can't
have multiple daemons running with the same worker id, but you may run as
many workers as you want.

As long as the database is shared (or you can replicate to multiple
databases), the Rebuild Queue daemons can be running on totally different
servers and then syncing to the others in your web farm.

You may also want to 'nice' these processes so they don't overpower the
server when they wake up to do some work.

Throttling
----------

You may also throttle the rebuilding of certain templates or types of
templates. That is, you may want to limit the rebuilding of category
archives to once per day.

    ./RebuildQueue.pl -throttle category=8640

Throttle times are given in seconds.

Or perhaps you want to only build a given template once every hour,
regardless of how many times it is requested to rebuild through the MT
interface or comment system. The template's id is 10.

    ./RebuildQueue.pl -throttle 10=360

You may repeat the -throttle switch as many times as you require to
specify your rules.


Example
=======

Lets say you have a few weblogs that are used to publish a set of media
web sites. The pages published are fairly heavy with content and/or
comments and take time to process, so you want to shift that work to
the Rebuild Queue instead. You also have 3 web servers that handle visitor
traffic and 1 that is used by your bloggers to publish the content.

    mt.zine.com (MT installation)
    www, www2, www3.zine.com (web farm for visitors; load balanced)

On mt.zine.com, you'd have your typical MT installation plus the Rebuild
Queue plugin.

You set up a cron job that runs the Rebuild Queue daemon.

*/15 * * * * cd /path/to/RebuildQueue; ./RebuildQueue.pl -daemonize

You also set up a cron job that handles syncing to the web servers:

10,25,40,55 * * * * /path/to/RebuildSync.sh

RebuildSync.sh is a custom script, containing:

    #!/bin/sh
    cd /path/to/RebuildQueue
    RSYNC_RSH=ssh
    ./RebuildQueue.pl -sync -to user@www: -to user@www2: -to user@www3:

The sync command takes all files that the Rebuild Queue daemon has rebuilt
and rsyncs them to the servers you specify. Note that the physical file
paths as they exist on the "mt.zine.com" server must be the same on the
other servers to match up.


Availability
============

The latest release of this plugin can be found at this address:

    http://code.sixapart.com/


License
=======

This plugin is released under the Artistic License.


Authors
=======

Brad Choate and Jay Allen of Six Apart

