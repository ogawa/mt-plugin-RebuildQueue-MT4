package MT::Plugin::RebuildQueueList;


use strict;
use MT 3.3;
use base 'MT::Plugin';

use MT;
use MT::FileInfo;
use RebuildQueue::File;
use POSIX qw( strftime );

our $VERSION        = '1.051';
our $SCHEMA_VERSION = '1.01';
our $ENABLED        = 1;

my $plugin = new MT::Plugin::RebuildQueueList({
    name           => "Rebuild Queue List",
    description    => "Lightweight GUI for the RebuildQueue Interface.",
    version        => $VERSION,
    author_name    => "Six Apart, Ltd.",
    author_link    => "http://www.sixapart.com/",
    plugin_link    => "http://code.sixapart.com/",
    icon           => "rebuildq.gif",
	app_methods => {
        'MT::App::CMS'  => {
            'rq_list' => \&list,
			'rq_delete' => \&rq_delete,
        }
    },
	callbacks => {
		'MT::App::CMS::AppTemplateSource.list_blog' => \&add_queue_list_link,
		'MT::App::CMS::AppTemplateParam.menu' => \&verify_permission,
	},
});

MT->add_plugin($plugin);
MT->add_plugin_action('blog','../../mt.cgi?__mode=rq_list', "Show rebuild queue for this blog");


#sub init {
#	my $app = shift;
#	$app->SUPER::init(@_) or return;
#	$app->add_methods(
#		list => \&list,
#		rq_delete => \&rq_delete,
#	);
#	$app->{default_mode} = 'list';
#	$app->{requires_login} = 1;
#	$app;
#}



sub list {
	my $app = shift;
	return $app->error('Sorry, you do not have the correct permissions to view this.') unless $app->user->is_superuser;
	my $q = $app->{query};
	my (%fi_terms, %rq_args, %rq_terms);
	my ($limit, $offset, $blog_id, $filter, $filter_val);

	
	$offset = $q->param('offset') || 0;
	$filter = $q->param('filter');
	$filter_val = $q->param('filter_val');
	
	my $prefs = $app->list_pref('queue_list');
	$limit = $prefs->{rows} || 15;
	my $pagesize = "limit_$limit";

	if ($q->param('blog_id') && !$filter) {
		$fi_terms{blog_id} = $q->param('blog_id');
		$filter = 'blog_id';
		$filter_val = $q->param('blog_id');
	} elsif ($filter && $filter_val) {
		if ($filter eq 'blog_id') {
			$fi_terms{blog_id} = $filter_val;
		} else {
			$rq_terms{$filter} = $filter_val;
		}
	}

	# to be filtered
	$rq_args{sort} = 'build_time';
	$rq_args{direction} = 'descend';
#	$rq_args{unique} = '1'; -- removed because this should always be a 1:1 mapping, and it was ignoring %fi_terms when this was set

	my @files = MT::FileInfo->load( \%fi_terms, {
	    'join' => [ 'RebuildQueue::File', 'id',
					\%rq_terms,
	                \%rq_args
				],
		'offset' => $offset,
		'limit' => $limit,
	});
	
	my $total = MT::FileInfo->count( \%fi_terms, {
		'join' => [ 'RebuildQueue::File', 'id',
				\%rq_terms,
				],
     });
	
	my $get_workers = RebuildQueue::Plugin->instance->get_config_value('workers');
	my @workers;
	for (my $c=1;$c<=$get_workers;$c++) {
		push @workers, $c;
	}
	my $workers_loop = [ map { { id => $_ }} @workers ];
	
	my $queue_loop = [ map { { id => $_->id, url => substr(MT::Blog->load($_->blog_id)->site_url, 0, index(MT::Blog->load($_->blog_id)->site_url, "/", 8)) . $_->url,  type => $_->archive_type, entry_id => $_->entry_id } } @files ];

	my @file_ids = map { $_->id } @files;
	my @queue_items = RebuildQueue::File->load({ id => \@file_ids });
	my %item_loop = map { $_->id => $_ } @queue_items;
	for (@$queue_loop) {
		if ($item_loop{$_->{id}}) {
			my $ts = strftime("%Y%m%d%H%M%S", localtime($item_loop{$_->{id}}->build_time));
			$_->{build_time} = MT::Util::format_ts(undef, $ts);
			$_->{worker_id} = $item_loop{$_->{id}}->worker;
		}
	}
	# only show blogs with items in the queue
	my @get_blogs = MT::FileInfo->load( {}, {
	    'join' => [ 'RebuildQueue::File', 'id']
	});
	my @blog_ids = map { $_->blog_id } @get_blogs;
	
	my @blogs = MT::Blog->load({id => \@blog_ids});
	my $blogs_loop = [ map { { id => $_->id, name => $_->name } } @blogs];

	$app->add_breadcrumb("RebuildQueue List");
	$app->{breadcrumbs}[-1]{is_last} = 1;


	my $next_offset = ($offset+($limit+1)<=$total)?$offset+$limit:0;
	my $prev_offset = ($offset>0)?$offset-$limit:0;

	$app->build_page("plugins/RebuildQueue/tmpl/queue_list.tmpl", {
		queueloop => \@$queue_loop,
		blogs_loop => \@$blogs_loop,
		workers_loop => \@$workers_loop,
		
		object_type => 'queue_list',
		$pagesize => 1,
		position_actions_top => ($prefs->{bar} eq 'above' || $prefs->{bar} eq 'both'),
		position_actions_bottom => ($prefs->{bar} eq 'below' || $prefs->{bar} eq 'both'),
		position_actions_both => ($prefs->{bar} eq 'both'),

		saved_deleted => ($q->param("saved_deleted"))?"1":"0",
		filter => $filter,
		filter_val => $filter_val,
		offset => $offset,
		list_noncron => 1,
		list_start => $offset+1,
		list_end => ($offset + $#files+1),
		prev_offset_val => $prev_offset,
		prev_offset => ($offset != 0),
		next_offset_val => $next_offset,
		next_offset => ($next_offset>0),
		next_max => ($next_offset>0)?($total-($total % $limit)):0,
		return_args => "__mode=rq_list&filter=" . $filter . "&filter_val=" . $filter_val,
		list_total => $total,
		});
	
}

sub rq_delete {
	my $app = shift;
	my $q = $app->{query};
	my $return_args = $q->param('return_args');
	my @ids = $q->param('id');
	for my $id (@ids) {
		my $task = RebuildQueue::File->load($id);
		if ($task) {
			$task->remove;
		}
	}
    return $app->redirect($app->uri(mode => 'rq_list') . '&saved_deleted=1&' . $return_args);
}

sub add_queue_list_link {
	my ($cb, $app, $tmpl) = @_;
	if ($app->user->is_superuser) {
		my $find = qq|<li id="nav-settings">|;
		my $replace = <<HTML;
<li id="nav-queue">
	<a href="<TMPL_VAR NAME=SCRIPT_URL>?__mode=rq_list"><MT_TRANS phrase="RebuildQueue"></a><br />
	<MT_TRANS phrase="List items currently in the rebuild queue.">
</li>
HTML
		$$tmpl =~ s/$find/$replace$find/;
	}
}

sub verify_permission {
    my ($eh, $app, $param, $tmpl) = @_;
    unless ($app->user->is_superuser) {
        @{$param->{plugin_action_loop}} = grep { $_->{'orig_link_text'} ne 'Show rebuild queue for this blog' }
            @{$param->{plugin_action_loop}};
    }
}

1;

__END__
