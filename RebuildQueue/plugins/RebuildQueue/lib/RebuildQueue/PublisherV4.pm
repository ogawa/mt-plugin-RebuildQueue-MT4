# $Id$

package RebuildQueue::PublisherV4;

use base 'MT::WeblogPublisher';

use File::Spec;

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
        my $archiver = $pub->archiver($at)
            or return;
        my $blog = MT::Blog->load($q->blog_id, {cached_ok => 1})
            if $q->blog_id;

        my ($entry, $start, $end, $category, $author);
        $entry = MT::Entry->load($q->entry_id, {cached_ok => 1})
            if $q->entry_id;
        ($start, $end) = $archiver->date_range->($q->startdate)
            if $q->startdate;
        $category = MT::Category->load($q->category_id, {cached_ok => 1})
            if $q->category_id;
        $author = MT::Author->load($q->author_id, {cached_ok => 1})
            if $q->author_id;

        my $arch_root = $blog->archive_path
            or return $mt->error(MT->translate("You did not set your weblog Archive Path"));

        my $map = MT::TemplateMap->load($q->templatemap_id, {cached_ok => 1});
        $map->{__saved_output_file} = File::Spec->abs2rel($q->file_path, $arch_root);

        my(%cond);
        my $ctx = MT::Template::Context->new;
        $ctx->{current_archive_type} = $at;
        $ctx->stash('blog', $blog);

        if ($entry) {
            $ctx->stash('entry', $entry);
            $ctx->{current_timestamp}      = $entry->authored_on;
            $ctx->{modification_timestamp} = $entry->modified_on;
        }
        if ($start && $end) {
            $ctx->{current_timestamp}     = $start;
            $ctx->{current_timestamp_end} = $end;
        }
        $ctx->stash('archive_category', $category) if $category;
        $ctx->stash('author', $author) if $author;

        $pub->rebuild_file($blog, $arch_root, $map, $at, $ctx, \%cond,
                           1,
                           $category ? (Category  => $category) : (),
                           $entry    ? (Entry     => $entry   ) : (),
                           $start    ? (StartDate => $start   ) : (),
                           $end      ? (EndDate   => $end     ) : (),
                           $author   ? (Author    => $author  ) : (),
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
