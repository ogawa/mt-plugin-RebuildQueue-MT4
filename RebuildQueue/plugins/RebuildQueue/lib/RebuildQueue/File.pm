# $Id: File.pm 85 2006-08-12 20:46:40Z bchoate $

package RebuildQueue::File;

use strict;
use base 'MT::Object';

__PACKAGE__->install_properties({
    column_defs => {
        id         => 'integer not null',
        rebuild_me => 'boolean',
        sync_me    => 'boolean',
        priority   => 'integer',
        worker     => 'integer',
        build_time => 'integer',
    },
    defaults => {
        rebuild_me => 0,
        worker     => 1,
        sync_me    => 0,
        priority   => 5,
    },
    indexes => {
        rebuild_me => 1,
        sync_me    => 1,
        worker     => 1,
        priority   => 1,
        build_time => 1,
    },
    primary_key => 'id',
    datasource => 'rebuildq_file',
});

sub save {
    my $rqf = shift;
    $rqf->build_time(time) unless $rqf->build_time;
    $rqf->SUPER::save(@_);
}

sub fileinfo {
    my $rqf = shift;
    unless ($rqf->{__fileinfo}) {
        require MT::FileInfo;
        $rqf->{__fileinfo} = MT::FileInfo->load($rqf->id);
    }
    $rqf->{__fileinfo};
}

1;
