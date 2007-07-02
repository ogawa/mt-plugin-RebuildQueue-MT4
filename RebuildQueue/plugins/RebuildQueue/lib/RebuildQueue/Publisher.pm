# $Id: Publisher.pm 212 2007-02-14 04:03:22Z djacobs $

package RebuildQueue::Publisher;

use base 'MT::WeblogPublisher';

use MT::Promise qw(delay);
use MT::Util qw(archive_file_for start_end_week start_end_day
    start_end_month start_end_period);

sub rebuild_from_queue {
    my $pub = shift;
    my ($q) = @_;

    my $at = $q->archive_type or
        return $pub->error(MT->translate("Parameter '[_1]' is required",
            'ArchiveType'));

    # callback for custom archive types
    return unless MT->run_callbacks( 'RebuildQueue::ArchiveFilter',
        ArchiveType => $at,
        FileInfo => $q );
	
    if ($at ne 'index') {
        return 1 if $at eq 'None';
        my $blog = MT::Blog->load($q->blog_id, {cached_ok => 1})
            if $q->blog_id;

        my $entry;
        if ($at eq 'Individual') {
            $entry = ($at ne 'Category') ? (MT::Entry->load($q->entry_id, { cached_ok => 1 }) or
                return $pub->error(MT->translate("Parameter '[_1]' is required",
                    'Entry'))) : undef;
        } elsif ($at ne 'Category') {
            my($start, $end);
            if ($at eq 'Daily') {
                ($start, $end) = start_end_day($q->startdate, $blog);
            } elsif ($at eq 'Weekly') {
                ($start, $end) = start_end_week($q->startdate, $blog);
            } elsif ($at eq 'Monthly') {
                ($start, $end) = start_end_month($q->startdate, $blog);
            }
            $entry = MT::Entry->load({created_on => [$start, $end]},
                { range_incl => { created_on => 1 }, limit => 1}) or
                return $pub->error(MT->translate("Parameter '[_1]' is required",
                    'Entry'));
        }
        my $cat = MT::Category->load($q->category_id, { cached_ok => 1 })
            if $q->category_id;

        ## Load the template-archive-type map entries for this blog and
        ## archive type. We do this before we load the list of entries, because
        ## we will run through the files and check if we even need to rebuild
        ## anything. If there is nothing to rebuild at all for this entry,
        ## we save some time by not loading the list of entries.
        my $map = MT::TemplateMap->load($q->templatemap_id);
        my $file = archive_file_for($entry, $blog, $at, $cat, $map);
        if (!defined($file)) {
            return $pub->error(MT->translate($blog->errstr()));
        }
        $map->{__saved_output_file} = $file;

        my(%cond);
        my $ctx = MT::Template::Context->new;
        $ctx->{current_archive_type} = $at;

        $at ||= "";

        if ($at eq 'Individual') {
            $ctx->stash('entry', $entry);
            $ctx->{current_timestamp} = $entry->created_on;
            $ctx->{modification_timestamp} = $entry->modified_on;
        } elsif ($at eq 'Daily') {
            my($start, $end) = start_end_day($entry->created_on, $blog);
            $ctx->{current_timestamp} = $start;
            $ctx->{current_timestamp_end} = $end;
            my $entries = sub {
                my @e = MT::Entry->load({ created_on => [ $start, $end ],
                                          blog_id => $blog->id,
                                          status => MT::Entry::RELEASE() },
                                        { range_incl => { created_on => 1 } });
                \@e;
            };
            $ctx->stash('entries', delay($entries));
        } elsif ($at eq 'Weekly') {
            my($start, $end) = start_end_week($entry->created_on, $blog);
            $ctx->{current_timestamp} = $start;
            $ctx->{current_timestamp_end} = $end;
            my $entries = sub {
                my @e = MT::Entry->load({ created_on => [ $start, $end ],
                                          blog_id => $blog->id,
                                          status => MT::Entry::RELEASE() },
                                        { range_incl => { created_on => 1 } });
                \@e;
            };
            $ctx->stash('entries', delay($entries));
        } elsif ($at eq 'Monthly') {
            my($start, $end) = start_end_month($entry->created_on, $blog);
            $ctx->{current_timestamp} = $start;
            $ctx->{current_timestamp_end} = $end;
            my $entries = sub {
                my @e = MT::Entry->load({ created_on => [ $start, $end ],
                                          blog_id => $blog->id,
                                          status => MT::Entry::RELEASE() },
                                        { range_incl => { created_on => 1 } });
                \@e;
            };
            $ctx->stash('entries', delay($entries));
        } elsif ($at eq 'Category') {
            unless ($cat) {
                return $pub->error(MT->translate(
                    "Building category archives, but no category provided."));
            }
            $ctx->stash('archive_category', $cat);
            my $entries = sub {
                my @e = MT::Entry->load({ blog_id => $blog->id,
                                          status => MT::Entry::RELEASE() },
                                        { 'join' => [ 'MT::Placement', 'entry_id',
                                          { category_id => $cat->id } ] });
                \@e;
            };
            $ctx->stash('entries', delay($entries));
        }

        my $fmgr = $blog->file_mgr;
        my $arch_root = $blog->archive_path;
        return $pub->error(MT->translate("You did not set your Local Archive Path"))
            unless $arch_root;

        my ($start, $end) = ($at ne 'Category') ? 
            start_end_period($at, $entry->created_on) : ();

        ## For each mapping, we need to rebuild the entries we loaded above in
        ## the particular template map, and write it to the specified archive
        ## file template.
        $pub->rebuild_file($blog, $arch_root, $map, $at, $ctx, \%cond,
                          1,
                          Category => $cat,
                          Entry => $entry,
                          StartDate => $start,
                          ) or return;
    } else {
        $pub->rebuild_indexes(
            BlogID => $q->blog_id,
            Template => MT::Template->load($q->template_id, { cached_ok => 1 }),
            Force => 1,
        ) or return;
    }
    1;
}

1;
