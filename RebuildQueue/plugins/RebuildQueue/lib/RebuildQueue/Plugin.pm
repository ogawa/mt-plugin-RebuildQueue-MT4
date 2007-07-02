# $Id: Plugin.pm 249 2007-05-05 01:50:39Z jallen $

package RebuildQueue::Plugin;

# Rebuild Queue plugin for Movable Type
# Authors:
#   Brad Choate -- http://bradchoate.com/
#   Jay Allen -- http://jayallen.org/
#   Apperceptive -- http://www.apperceptive.com/
#
# Released under the Artistic License
#
# $Id: Plugin.pm 249 2007-05-05 01:50:39Z jallen $

use strict;
use MT 3.3;
use base 'MT::Plugin';

our $VERSION        = '1.06';
our $SCHEMA_VERSION = '1.01';
our $ENABLED        = 1;

my $plugin = new RebuildQueue::Plugin({
    name           => "Rebuild Queue",
    description    => "Queues rebuild operations for offline building.",
    object_classes => ['RebuildQueue::File'],
    version        => $VERSION,
    schema_version => $SCHEMA_VERSION,
    author_name    => "Six Apart, Ltd.",
    author_link    => "http://www.sixapart.com/",
    plugin_link    => "http://code.sixapart.com/",
    icon           => "rebuildq.gif",
    settings       => new MT::PluginSettings([
        ['workers',       { Default => 1,     Scope => 'system' }],
        ['rebuildq_sync', { Default => 0,     Scope => 'system' }],
        ['rebuildq_mode', { Default => 0,     Scope => 'blog'   }],
        ['rebuildq_cms_override', { Default => 1,     Scope => 'blog'   }],
        ['worker',        { Default => undef, Scope => 'blog'   }],
    ]),
    callbacks      => {
        'BuildFileFilter' => {
            priority => 10,
            code     => \&build_file_filter,
        },
        'BuildFile' => {
            priority => 10,
            code     => \&build_file,
        },
        'MT::FileInfo::post_remove' => {
            priority => 1,
            code     => \&fileinfo_post_remove,
        },
        'MT::FileInfo::post_remove_all' => {
            priority => 1,
            code     => \&fileinfo_post_remove_all,
        },
        'CMSUploadFile' => {
            priority => 1,
            code     => \&cms_upload_file,
        },
    },
    system_config_template => \&system_config_template,
    blog_config_template   => \&blog_config_template,
});

if (!MT->instance->isa('RebuildQueue::Daemon')) {
    MT->add_plugin($plugin);
}

sub instance {
    $plugin;
}

sub enable {
    $ENABLED = 1;
}

sub disable {
    $ENABLED = 0;
}

sub enabled {
    $ENABLED;
}

sub init_request {
    my $plugin = shift;
    my ($app) = @_;
	
    # Enable by default for Comment / TrackBack applications
    $plugin->enable;

	my $override = $plugin->blog_cms_override($app->param('blog_id'));

    # For CMS, disable in certain situations...
    if ($app->isa('MT::App::CMS') && $override) {
	
        my $mode = $app->mode;

        # Explicit rebuilds should bypass queue, but not sync.
        # Mode "rebuild-phase" is used for approve_item,
        # unapprove_item, handle_junk and not_junk methods and
        # should be processed by RebuildQueue
        if ($mode =~ m/^rebuild(?!_phase)/) {
            $plugin->disable;

            # enable and queue rebuilds when rebuilding individual entries
            if ($mode eq 'rebuild') {
                if ($app->param('fs')) {
                    if ($app->param('type') =~ m/^entry-\d+$/) {
                        if ($app->param('next') eq '0') {
                            $plugin->enable;
                        }
                    }
                }
            }
        }
    }

    $plugin->SUPER::init_request(@_);
}

# The RebuildQueue can synchronize built pages, but in order to handle
# files uploaded through the interface, we need to manage our own
# FileInfo records. Upon synchronization of these, they can be removed.
sub cms_upload_file {
    my ($cb, %args) = @_;

    my $url = $args{Url};
    my $file = $args{File};
    return unless -f $file;

    return unless $plugin->sync_support;

    my $blog = $args{Blog};
    my $blog_id = $blog->id;
    return unless $plugin->blog_enabled($blog_id);

    require MT::FileInfo;
    my $base_url = $url;
    $base_url =~ s!^https?://[^/]+!!;
    my $fi = MT::FileInfo->load({ blog_id => $blog_id, url => $base_url });
    if (!$fi) {
        $fi = new MT::FileInfo;
        $fi->blog_id($blog_id);
        $fi->url($base_url);
        $fi->file_path($file);
    } else {
        $fi->file_path($file);
    }
    $fi->save;

    require RebuildQueue::File;
    my $rqf = RebuildQueue::File->load($fi->id);
    if (!$rqf) {
        $rqf = new RebuildQueue::File;
        $rqf->id($fi->id);
    }
    $rqf->worker($plugin->blog_worker($blog_id));
    $rqf->sync_me(1);
    $rqf->save;
}

sub fileinfo_post_remove {
    my ($cb, $fi) = @_;
    require RebuildQueue::File;
    if (my $rqf = RebuildQueue::File->load($fi->id)) {
        $rqf->remove;
    }
}

sub fileinfo_post_remove_all {
    my ($cb, $fi) = @_;
    require RebuildQueue::File;
    RebuildQueue::File->remove_all;
}

sub system_config_template {
    my $workers = $plugin->get_config_value('workers', 'system');

    my $max = 10;
    $max = $workers + 10 if $workers >= $max;

    my $worker_html = '';
    for (my $i = 1; $i <= $max; $i++) {
        $worker_html .= qq{
    <option value="$i" <TMPL_IF NAME=WORKERS_$i>selected="selected"</TMPL_IF>>$i</option>};
    }

    return <<HTML;
<div class="setting">
<div class="label"><MT_TRANS phrase="Number of Workers:"></div>
<div class="field"><ul><li><select name="workers">
$worker_html
</select></li></ul>
</div>
</div>

<div class="setting">
<div class="label"><MT_TRANS phrase="Synchronize:"></div>
<div class="field"><ul><input name="rebuildq_sync" type="checkbox" <TMPL_IF NAME=REBUILDQ_SYNC_1>checked="checked"</TMPL_IF> value="1" />
<MT_TRANS phrase="Check to support synchronization of queued items with other servers.">
</li></ul>
</div>
</div>
HTML
}

sub blog_config_template {
    my $workers = $plugin->get_config_value('workers', 'system');
    my $worker_html = '';
    my $toggle = '';
    if ($workers > 1) {
        $toggle = q{onclick="toggleSubPrefs(this)"};
        $worker_html = <<HTML;
<div class="setting" id="rebuildq_mode-prefs" style="display: <TMPL_IF NAME=REBUILDQ_MODE>block<TMPL_ELSE>none</TMPL_IF>">
<div class="label"><MT_TRANS phrase="Force Building to Worker:"></div>
<div class="field"><ul><li><select name="worker">
    <option value="" <TMPL_IF NAME=WORKER_>selected="selected"</TMPL_IF>>(Random)</option>
HTML
        for (my $i = 1; $i <= $workers; $i++) {
            $worker_html .= <<HTML;
    <option value="$i" <TMPL_IF NAME=WORKER_$i>selected="selected"</TMPL_IF>>$i</option>
HTML
        }
        $worker_html .= <<HTML;
</select></li></ul>
</div>
</div>
HTML
    }

    return <<HTML;

	
<div class="setting">
<div class="label"><MT_TRANS phrase="Enabled for this Weblog?"></div>
<div class="field"><ul><li><input $toggle type="checkbox" id="rebuildq_mode" name="rebuildq_mode" value="1" <TMPL_IF REBUILDQ_MODE>checked="checked"</TMPL_IF> /> <MT_TRANS phrase="Check to allow this weblog to be rebuilt using the Rebuild Queue."></li></ul>
</div>
</div>

<div class="setting">
<div class="label"><MT_TRANS phrase="Allow CMS to override Rebuild Queue?"></div> 
<div class="field"><ul><li><input type="checkbox" id="rebuildq_cms_override" name="rebuildq_cms_override" value="1" <TMPL_IF REBUILDQ_CMS_OVERRIDE>checked="checked"</TMPL_IF> /> <MT_TRANS phrase="Uncheck to push all pages to Rebuild Queue, regardless of context. If Checked, manual rebuilds will circumvent the RebuildQueue."></li></ul></div>
</div>



$worker_html
HTML
}

# If the user enables rebuild queue for a blog, the blog must be configured
# to 'custom' for dynamic templates. This lets the FileInfo table be populated
# which is necessary.
sub save_config {
    my $plugin = shift;
    my ($param, $scope) = @_;
    if (($scope =~ m/^blog:(\d+)/) && ($param->{rebuildq_mode})) {
        # check for rebuildq_mode enabled...
        my $blog = MT::Blog->load($1);
        if (($blog->custom_dynamic_templates || '') eq 'none') {
            $blog->custom_dynamic_templates('custom');
            $blog->save;
        }
    }
    $plugin->SUPER::save_config(@_);
}

sub sync_support {
    $plugin->get_config_value('rebuildq_sync') ? 1 : 0;
}

sub blog_enabled {
    my $plugin = shift;
    my ($blog_id) = @_;
    $plugin->get_config_value('rebuildq_mode', 'blog:'.$blog_id) ? 1 : 0;
}

sub blog_cms_override {
    my $plugin = shift;
    my $blog_id = shift || '';
    $plugin->get_config_value('rebuildq_cms_override', 'blog:'.$blog_id) ? 1 : 0;
}

sub blog_worker {
    my $plugin = shift;
    my ($blog_id) = @_;
    my $workers = $plugin->get_config_value('workers') || 1;
    my $worker = $plugin->get_config_value('worker', 'blog:'.$blog_id);
    $worker = 1 if (defined $worker) && ($worker ne "") && ($worker > $workers);
    if (!defined($worker) || ($worker eq '')) {
        $worker = int(rand($workers)) + 1;
    }
    return $worker;

}

# Adds an element to the rebuild queue when the plugin is enabled.
sub build_file_filter {
    my ($cb, %args) = @_;
    return 1 unless $ENABLED;

    my $fi = $args{FileInfo};
    if (!$fi) {
        $cb->error("Blog " . $args{Blog}->id . " is not configured for FileInfo support.");
        return 1;
    }
    return 1 unless $plugin->blog_enabled($fi->blog_id);

    require RebuildQueue::File;
    my $rqf = RebuildQueue::File->load($fi->id);
    if ($rqf) {
        return 0 if $rqf->rebuild_me;
    } else {
        $rqf = new RebuildQueue::File;
        $rqf->id($fi->id);
    }

    $rqf->rebuild_me(1);
    $rqf->sync_me(0);
    $rqf->build_time(0);
    $rqf->worker($plugin->blog_worker($fi->blog_id));

    my $at = $fi->archive_type || '';

    # Default priority assignment....
    if ($at eq 'Individual') {
        require MT::TemplateMap;
        my $map = MT::TemplateMap->load($fi->templatemap_id, { cached_ok => 1 });
        # Individual archive pages that are the 'permalink' pages should
        # have highest build priority.
        if ($map && $map->is_preferred) {
            $rqf->priority(1);
        } else {
            $rqf->priority(9);
        }
    } elsif ($at eq 'index') {
        # Index pages are second in priority, if they are named 'index'
        # or 'default'
        if ($fi->file_path =~ m!/(index|default|atom|feed)!i) {
            $rqf->priority(3);
        } else {
            $rqf->priority(9);
        }
    } elsif (($at eq 'Monthly') || ($at eq 'Weekly') || ($at eq 'Daily')) {
        $rqf->priority(5);
    } elsif ($at eq 'Category') {
        $rqf->priority(7);
    }

    $rqf->save;

    return 0;
}

# Something was built while the queue itself was disabled; make sure
# the item is marked for syncing.
sub build_file {
    my ($cb, %args) = @_;

    # preconditions
    return unless $plugin->sync_support;
    my $fi = $args{FileInfo} or return $cb->error("Blog is not configured for FileInfo support.");
    return unless $plugin->blog_enabled($fi->blog_id);

    require RebuildQueue::File;
    my $rqf = RebuildQueue::File->load($fi->id);
    if (!$rqf) {
        $rqf = new RebuildQueue::File;
        $rqf->id($fi->id);
        $rqf->build_time(time);
        $rqf->worker($plugin->blog_worker($fi->blog_id));
        $rqf->sync_me(1);
        $rqf->save;
    } else {
        if (!$rqf->rebuild_me) {
            if (!$rqf->sync_me) {
                $rqf->sync_me(1);
                $rqf->build_time(time);
                $rqf->worker($plugin->blog_worker($fi->blog_id));
                $rqf->save;
            }
        }
    }
}

1;

__END__

=head1 NAME

RebuildQueue::Plugin - Movable Type plugin for distributed rebuilding.

=head1 SYNOPSIS

=head1 TWEAKING

You may wish to further tune the rebuild queue items. To do so, you
should hook into the RebuildQueue::File::pre_save MT callback. This
gives you a chance to modify the priority and build_time properties
of a RebuildQueue::File record before it is saved. Here's an example:

Within a separate plugin, register for the callback:

    MT->add_callback('RebuildQueue::File', 5, undef, \&rqf_fix);

Then, define your callback routine:

    sub rqf_fix {
        my ($cb, $obj, $orig) = @_;
        my $fi = $obj->fileinfo;

        # only tweak when being saved to the rebuild queue
        return unless $obj->rebuild_me;

        # Sidebar elements can be built last.
        if ($fi->file_path =~ m!/sidebar/!) {
            $obj->priority(1000); # really low priority
        }

        # Forces pages built for nagios to run on a particular
        # worker that also has access to nagios local data.
        if ($fi->file_path =~ m!/nagios/!) {
            $obj->worker(3);
        }
    }

As you can see, it's possible to really fine-tune your rebuild
queue.

=head1 AUTHORS

Brad Choate, Jay Allen and Apperceptive

=head1 COPYRIGHT

Copyright (c) 2006, Brad Choate and Jay Allen. This is free software.
It may be distributed and modified under the same terms as Perl itself.

=head1 AVAILABILITY

http://code.sixapart.com/

=cut
