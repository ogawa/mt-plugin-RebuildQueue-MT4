# $Id: Daemon.pm 250 2007-05-14 17:26:26Z djacobs $

package RebuildQueue::Daemon;

use strict;

use base 'MT';

use MT::Blog;
use MT::Entry;
use MT::Category;
use MT::Template;
use MT::TemplateMap;
use MT::FileInfo;
use MT::Placement;
use MT::Template::Context;
use RebuildQueue::Publisher;
use RebuildQueue::File;
use Fcntl qw( :DEFAULT :flock );
use Symbol;
use Time::HiRes qw(gettimeofday tv_interval);

sub init {
    my $mt = shift;
    $mt->SUPER::init();
    $mt->{WeblogPublisher} = new RebuildQueue::Publisher;
    $mt->config('NoPlacementCache', 1);
    $mt;
}

my $unlock;

END {
    $unlock->() if $unlock;
}

sub sync {
    my $mt = shift;
    my (%opt) = @_;

    my $nap_time  = $opt{'sleep'}   || 5;
    my $daemonize = $opt{daemonize} || 0;
    my $worker    = $opt{worker}    || [];
    my $targets   = $opt{target}    || [];
    my $rsync_opt = $opt{rsync_opt} || '-a';

    # We need the plugin for getting settings, but not for anything
    # else...
    require RebuildQueue::Plugin;
    my $plugin = RebuildQueue::Plugin->instance;
    $plugin->disable;

    my $sync_support = $plugin->sync_support;
    unless ($sync_support) {
        print "Synchronization is not enabled.\n";
        exit 1;
    }

    my $worker_id = join ',', sort @$worker;
    $worker_id = 'all' unless $worker_id;
    unless ($unlock = $mt->_lock("sync-$worker_id")) {
        exit 1;
    }

    my $stop = 0;
    local $SIG{INT}  = sub { $stop = 1 };
    local $SIG{QUIT} = sub { $stop = 1 };

    $| = 1;

    print "RebuildQueue sync daemon running...\n" if $daemonize;

    while (!$stop) {
        my $sync_set = [gettimeofday];
        my $iter = RebuildQueue::File->load_iter({
            sync_me => 1, (@$worker ? ( worker => $worker ) : ()),
        }, { 'sort' => 'priority', direction => 'ascend' });
        my @rqf;
        my @files;
        my @static_fileinfo;
        while (my $rqf = $iter->()) {
            my $fi = $rqf->fileinfo;
            if ($fi && (-f $fi->file_path)) {
                print _summary($fi) . "\n";
                push @files, $fi->file_path;
				# Only do this if we're sure $fi exists. 
	            unless ($fi->template_id) {
	                # static file
	                push @static_fileinfo, $fi;
	            }
            } else {
                if (!$fi) {
                    print "Warning: couldn't locate fileinfo record id " . $rqf->id . "\n";
                } else {
                    if (!-f $fi->file_path) {
                        print "Warning: couldn't locate file: " . $fi->file_path . "\n";
                    }
					# Only do this if we're sure $fi exists. 
		            unless ($fi->template_id) {
		                # static file
		                push @static_fileinfo, $fi;
		            }
                }
            }
            push @rqf, $rqf;

        }
        my $synced = 0;
        if (@files) {
            $synced = scalar @files;
            require File::Spec;
            my $file = File::Spec->catfile($mt->config('TempDir'), "rebuildq-rsync-$$.lst");
            open FOUT, ">$file";
            print FOUT join("\n", @files) . "\n";
            close FOUT;
            foreach my $target (@$targets) {
                my $cmd = "rsync $rsync_opt --files-from=\"$file\" / \"$target\"";
                print "Syncing files to $target...";
                my $start = [gettimeofday];
                my $res = system $cmd;
                my $exit = $? >> 8;
                if ($exit != 0) {
                    # TBD: notification to administrator
                    # At the very least, log to MT activity log.
                    print STDERR "Error during rsync of files in $file...\n";
                    print STDERR "Command: $cmd\n";
                    print STDERR $res;
                    exit 1;
                } else {
                    print sprintf("done! (%0.02fs)\n", tv_interval($start));
                }
            }
            unlink $file;
            # clear sync flags...
            $_->remove foreach @rqf;
            $_->remove foreach @static_fileinfo;
        }
        if ($synced) {
            print "-- set complete ($synced files in " . sprintf("%0.02f", tv_interval($sync_set)) . " seconds)\n";
        } else {
            print "No files available to sync.\n" unless $daemonize;
        }
        if (!$daemonize) {
            last;
        }
        sleep $nap_time;
    }
    print "\nShutting down RebuildQueue...\n" if $daemonize;
}

sub priority_build_order($$) {
    my ($a, $b) = @_;
    if ($a->priority == $b->priority) {
        return $a->build_time <=> $b->build_time;
    }
    $a->priority <=> $b->priority;
}

sub run {
    my $mt = shift;
    my (%opt) = @_;

    my $nap_time  = $opt{'sleep'}   || 5;
    my $daemonize = $opt{daemonize} || 0;
    my $throttles = $opt{throttle}  || {};
    my $worker    = $opt{worker}    || [];
    my $max_items = $opt{load}      || 10;

    my $worker_id = join ',', sort @$worker;
    $worker_id = 'all' unless $worker_id;
    unless ($unlock = $mt->_lock("daemon-$worker_id")) {
        # an existing daemon is running with this worker id. don't
        # allow a second to run.
        exit 1;
    }

    # We need the plugin for getting settings, but not for anything
    # else...
    require RebuildQueue::Plugin;
    my $plugin = RebuildQueue::Plugin->instance;
    $plugin->disable;

    my $sync_support = $plugin->sync_support;

    my $stop = 0;
    local $SIG{INT}  = sub { $stop = 1 };
    local $SIG{QUIT} = sub { $stop = 1 };

    $| = 1;

    $mt->cleanup_rebuild_queue;

    print "RebuildQueue build daemon running...\n" if $daemonize;

    my $pub = $mt->publisher;

    while (!$stop) {
        my @items = RebuildQueue::File->load({
            rebuild_me => 1, (@$worker ? ( worker => $worker ) : ()),
            build_time => [undef, time],
        }, {
            limit      => $max_items,
            'sort'     => 'priority',
            direction  => 'ascend',
            range_incl => { build_time => 1 }
        });
        @items = sort priority_build_order @items;

        my $start_set = [gettimeofday];
        my $rebuilt = 0;
        foreach my $rqf (@items) {
            last if $stop;
            my $fi = $rqf->fileinfo;
            if (!$fi) {
                print "Warning: couldn't locate fileinfo record id " . $rqf->id . "\n";
                $rqf->remove;
                next;
            }

            my $mtime = (stat($fi->file_path))[9];

            my $throttle = $throttles->{$fi->template_id}
                        || $throttles->{lc $fi->archive_type};

            # think about-- throttle by archive type or by template
            if ($throttle) {
                if (-f $fi->file_path) {
                    my $time = time;
                    if ($time - $mtime < $throttle) {
                        # ignore rebuilding this file now; not enough
                        # time has elapsed for rebuilding this file...
                        next;
                    }
                }
            }
            print _summary($fi);
            my $start = [gettimeofday];
            my $builderr = 0;
            defined($pub->rebuild_from_queue($fi)) or $builderr = 1;
            if (my $err = $builderr ? $pub->errstr : undef) {
                print STDERR "\n\tERROR: $err";
            } else {
		# this sometimes stops files from rebuilding overzealously.
                #my $mtime2 = (stat($fi->file_path))[9];
                #if ($mtime != $mtime2) {
                    # file was updated; mark for syncing
                    if ($sync_support) {
                        $rqf->sync_me(1);
                        $rqf->rebuild_me(0);
                        $rqf->build_time(time);
                        $rqf->save;
                    } else {
                        $rqf->remove;
                    }
                #} else {
                #    # touch file to help throttle mechanism
                #    my $now = time;
                #    utime $now, $now, $fi->file_path;
                #    $rqf->remove;
                #}
                $rebuilt++;
                print " (" . sprintf("%0.02f", tv_interval($start)) . "s)\n";
            }
        }
        if ($rebuilt) {
            MT::Object->driver->clear_cache();
            $mt->request->reset;
            print "-- set complete ($rebuilt files in " . sprintf("%0.02f", tv_interval($start_set)) . " seconds)\n";
        } else {
            last unless $daemonize;
        }
        last if $stop;
        sleep $nap_time;
    }

    print "\nShutting down RebuildQueue...\n" if $daemonize;
}

# Method to remove any RebuildQueue::File objects that
# are no longer requiring rebuild or sync operations.
sub cleanup_rebuild_queue {
    my $mt = shift;
    my @recs = RebuildQueue::File->load({
        rebuild_me => 0,
        sync_me => 0
    });
    $_->remove foreach @recs;
}

# Summarizes the current queue item for display in the log.
sub _summary {
    my $fi = shift;
    my $blog = MT::Blog->load($fi->blog_id, { cached_ok => 1 });
    my $cat = MT::Category->load($fi->category_id, { cached_ok => 1} ) if $fi->category_id;
    my $entry = MT::Entry->load($fi->entry_id, { cached_ok => 1} ) if $fi->entry_id;
    my $tmpl = MT::Template->load($fi->template_id, { cached_ok => 1} ) if $fi->template_id;
    my $root = $blog->site_path;
    my $file = $fi->file_path;
    $file =~ s/^\Q$root\E//;
    $file =~ s/^\///;
    # Output summary
    # Blog name: /path/to/file (Template)
    if (!$fi->template_id) {
        # static file being synced
        sprintf("%s: %s", $blog->name, $file);
    } else {
        sprintf("%s: %s (%s)", $blog->name, $file, $tmpl->name . ' - ' . ( $entry ? $entry->title : $cat ? $cat->label : $fi->archive_type . " archive"));
    }
}

sub _lock {
    my $mt = shift;
    my ($id) = @_;

    require MT::ConfigMgr;
    my $cfg = MT::ConfigMgr->instance;

    my $temp_dir = $cfg->TempDir;
    my $mt_dir = MT->instance->{mt_dir};
    $mt_dir =~ s/[^A-Za-z0-9]+/_/g;
    my $lock_name = "rebuildq-$mt_dir-$id.lock";
    require File::Spec;
    $lock_name = File::Spec->catfile($temp_dir, $lock_name);

    if ($cfg->UseNFSSafeLocking) {
        require Sys::Hostname;
        my $hostname = Sys::Hostname::hostname();
        my $lock_tmp = $lock_name . '.' . $hostname;
        my $tries = 10;           ## no. of seconds to keep trying
        my $lock_fh = gensym();
        open $lock_fh, ">$lock_tmp" or return;
        select((select($lock_fh), $|=1)[0]);  ## Turn off buffering
        my $got_lock = 0;
        for (0..$tries-1) {
            print $lock_fh $$, "\n"; ## Update modified time on lockfile
            if (link($lock_tmp, $lock_name)) {
                $got_lock++; last;
            } elsif ((stat $lock_tmp)[3] > 1) {
                ## link() failed, but the file exists--we got the lock.
                $got_lock++; last;
            }
            sleep 1;
        }
        close $lock_fh;
        unlink $lock_tmp;
        return unless $got_lock;
        return sub { unlink $lock_name };
    } else {
        my $lock_fh = gensym();
        sysopen $lock_fh, $lock_name, O_RDWR|O_CREAT, 0666
            or return;
        my $lock_flags = LOCK_EX | LOCK_NB;
        unless (flock $lock_fh, $lock_flags) {
            # Advisory lock is still active
            close $lock_fh;
            return;
        }
        return sub { close $lock_fh; unlink $lock_name };
    }
}

1;
