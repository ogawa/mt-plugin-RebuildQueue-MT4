#!/usr/bin/perl

# $Id: RebuildQueue.pl 107 2006-11-05 02:13:32Z jallen $

use strict;

# This prevents MT from reprocessing this .pl script during the plugin
# load loop...

return 1 if $RebuildQueue::included;
$RebuildQueue::included = 1;

if ($0 =~ m/RebuildQueue/i) {
    # we're running as our own process!

    # Invoke the Daemon
    require FindBin;
    require File::Spec;
    $ENV{MT_HOME} ||= File::Spec->catdir($FindBin::Bin, "..", "..");
    unshift @INC, File::Spec->catdir($ENV{MT_HOME}, "lib");
    unshift @INC, File::Spec->catdir($ENV{MT_HOME}, "extlib");
    unshift @INC, File::Spec->catdir($FindBin::Bin, "lib");

    require Getopt::Long;
    my $daemonize = 0;
    my $sleep     = 5;
    my $help      = 0;
    my %throttle;
    my @worker;
    my $worker    = '';
    my $sync      = 0;
    my $rsync_opt = '';
    my @target;
    my $load      = 10;

    Getopt::Long::GetOptions(
        "daemonize"   => \$daemonize,
        "sleep=i"     => \$sleep,
        "help|?"      => \$help,
        "throttle=i"  => \%throttle,
        "worker=s"    => \$worker,
        "sync"        => \$sync,
        "to|target=s" => \@target,
        "rsync=s"     => \$rsync_opt,
        "load=i"      => \$load,
    );

    if ($sync && !@target) {
        $help = 1;
        print "No targets specified!\n";
    }

    if ($help) {
        require Pod::Usage;
        Pod::Usage::pod2usage(
            -exitstatus => 1,
            -message => "RebuildQueue.pl usage"
        );
    }

    foreach my $key (keys %throttle) {
        if ($key =~ m/,/) {
            my $value = delete $throttle{$key};
            my @keys = split(/,/,$key);
            $throttle{$_} = $value foreach @keys;
        }
    }
    if ($worker =~ m/,/) {
        @worker = split(/,/, $worker);
    } else {
        @worker = ($worker) if $worker =~ m/^\d+$/;
    }

    require RebuildQueue::Daemon;
    if ($sync) {
        RebuildQueue::Daemon->new->sync(
            daemonize => $daemonize,
            'sleep'   => $sleep,
            worker    => \@worker,
            target    => \@target,
            rsync_opt => $rsync_opt,
        );
    } else {
        RebuildQueue::Daemon->new->run(
            daemonize => $daemonize,
            'sleep'   => $sleep,
            throttle  => \%throttle,
            worker    => \@worker,
            load      => $load,
        );
    }
} else {
    require RebuildQueue::Plugin;
}

1;

__END__

=head1 NAME

RebuildQueue.pl - A plugin to manage offline rebuilding operations.

=head1 SYNOPSIS

    RebuildQueue.pl -daemon -worker 2 -sleep 10

    RSYNC_RSH=ssh RebuildQueue.pl -sync -to user@server2:

=head1 OPTIONS

=over 4

=item B<-d[aemonize]>

Instructs the RebuildQueue script to daemonize itself, which is to say it
will remain running and waiting for new files to publish until it is
stopped (either by killing the process or using CTRL+C).

=item B<-sl[eep]> (seconds)

Option to specify the number of seconds to delay inbetween checking for
new files to publish. The default is 5 seconds.

=item B<-l[oad]> (number)

Use to specify the number of files to process in any given set of the
Rebuild Queue rebuild daemon.

=item B<-w[orker]> (id)

Worker ID for the RebuildQueue being invoked.

=item B<-th[rottle]> archive_type=(seconds)

=item B<-th[rottle]> template_id=(seconds)

Specifies the number of seconds required to elapse before rebuilding a particular archive type and/or template id. This switch can be repeated as required.

    RebuildQueue.pl -throttle index=360 -throttle 15=8640

The above command builds index type templates at most once per hour and the template with id '10' is built at most once per day.

If specifying a throttle for an archive type, the type must be one of: "index", "monthly", "daily", "category", "weekly", "individual".

You may also specify lists like this:

    RebuildQueue.pl -throttle index,category=360 monthly,15,30=8640

=item B<-sy[nc]>

Run in synchronization mode. Upon rebuilding files in daemon mode, files are marked as changed which allows this mode to then take them and replicate them to another server (or multiple servers). Identify the server(s) you want to sync with using the "-to" switch.

=item B<-to> E<lt>rsync_targetE<gt>

A root 'rsync' address to use for sync operation. Must be used in combination with the -sync switch (one or more targets may be specified).

    RebuildQueue.pl -sync -to user@hostname:

Paths on the local server and remote server should match.

=item B<-r[sync]> "(options)"

Allows you to provide a list of rsync switches to the rsync command that is used to sync when running in sync mode. The default value is "-a". Be sure to quote this parameter so the switches provided are not seen as parameters to the RebuildQueue.pl script itself.

=back

=head1 TROUBLESHOOOTING

RebuildQueue automatically tries to find your MT directory for inclusion of code libraries.  However, sometimes this may fail leading to an error such as this:

 Base class package "MT" is empty.
    (Perhaps you need to 'use' the module which defines that package first.)
 at /PATH/TO/RebuildQueue/lib/RebuildQueue/Daemon.pm line 7

If this happens, you can set the MT_HOME variable in your environment or on the command line like so using the bash shell:

    export MT_HOME=/www/cgi-bin/mt/; RebuildQueue.pl [options]

=head1 AUTHORS

Brad Choate - L<http://bradchoate.com/>
Jay Allen - L<http://jayallen.org/>

=head1 COPYRIGHT

Copyright 2006, Brad Choate / Jay Allen.

This plugin is free software; you may redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AVAILABILITY

The latest version of this plugin can be found in the Six Apart
Subversion code respository, located here:

    http://code.sixapart.com/svn/mtplugins/trunk/RebuildQueue/

=cut
