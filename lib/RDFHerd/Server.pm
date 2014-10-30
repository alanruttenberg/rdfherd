# Generic Server Object
#
# Copyright © 2008-2010  Creative Commons Corp.
#
# $Id: Server.pm 3580 2010-08-18 22:51:54Z bawden $

package RDFHerd::Server;

use 5.008_005;
use strict;
use integer;
use Carp;
use DB_File;
use English '-no_match_vars';
use Fcntl qw(O_RDONLY O_RDWR O_CREAT);
use File::Copy qw(copy);
use POSIX qw(SIGTERM ENOENT);
use RDFHerd::CacheUtils qw(cache_init scratch_init cache_fold
			   transaction_in_progress
			   server_initialized
			   uri_string
			   bundle_id
			   bundle_version bundle_ok_version
			   bundle_name
			   bundle_graphs
			   bundle_prop bundle_ok_prop
			   bundle_file_loaded_ok
			   bundle_graph_cleared_ok);
use RDFHerd::Log;
use RDFHerd::Utils qw(hash_compose erase_file
		      mjdtime mjdtime_cmp mjdtime_add
		      password_read yes_or_no);
use RDFHerd;
#use FileHandle;

our (@ISA, $VERSION);
@ISA = qw(RDFHerd);
$VERSION = 1.18_01;

sub initialize {
    my ($self) = @_;
    $self->SUPER::initialize();
    $self->{bundle_cache} = {};
    if (exists($ENV{RDFHERD_SERVER_SKIP_LOAD_FILE})) {
	$self->{skip_load_file} = 1;
    }
}

sub load_db_init {
    my ($self) = @_;
    return if ($self->{load_db}); # only do this once...
    my $path = $self->path;
    my $ro = $self->{read_only};
    my $mode;
    if ($ro) {
	$self->state_lock_for_read;
	$mode = O_RDONLY;
    } else {
	$self->state_lock;
	$mode = O_RDWR | O_CREAT;
    }
    my %database;
    tie(%database, "DB_File", "$path/Loaded.db", $mode, 0666) or
	($ro and $ERRNO == ENOENT) or
	die "$ERRNO: $path/Loaded.db\n";
    unless ($ro) {
	$self->{load_log} =
	    new RDFHerd::Log("$path/Loaded.log",
			     \%database,
			     3,
			     \&cache_init,
			     \&scratch_init,
			     \&cache_fold);
    }
    $self->{load_db} = \%database;
    my $bid = transaction_in_progress(\%database);
    if ($bid) {
	$self->{now_updating} =
	    $self->find_bundle(bundle_name(\%database, $bid));
    } else {
	$self->{now_updating} = 0;
    }
}

sub load_db_erase {
    my ($self) = @_;
    my $path = $self->path;
    erase_file("$path/Loaded.db");
    erase_file("$path/Loaded.log");
}

sub load_db_save {
    (@_ == 2) or confess "\tBUG";
    my ($self, $dst) = @_;
    my $path = $self->path;
    return copy("$path/Loaded.log", $dst);
}

sub load_db_restore {
    (@_ == 2) or confess "\tBUG";
    my ($self, $src) = @_;
    my $path = $self->path;
    if (-e "$path/Loaded.log") {
	croak "Can't overwrite load data.";
    }
    erase_file("$path/Loaded.db");	# just in case...
    return copy($src, "$path/Loaded.log");
}

sub load_db {
    $_[0]->{load_db} or do {
	my ($self) = @_;
	$self->load_db_init();
	$self->{load_db};
    }
}

sub load_log {
    $_[0]->{load_log} or do {
	my ($self) = @_;
	$self->load_db_init();
	$self->{load_log};
    }
}

sub now_updating {
    my ($self) = @_;
    unless (exists($self->{now_updating})) {
	$self->load_db_init();
    }
    return $self->{now_updating};
}

sub sync_cache {
    my ($self) = @_;
    unless ($self->{read_only}) {
	$self->load_log->sync();
    }
}

sub initialized {
    return server_initialized($_[0]->load_db);
}

sub head_version {
    (@_ == 2) or confess "\tBUG";
    my ($self, $bundle) = @_;
    $self->sync_cache();	# be as up-to-date as possible...
    my $db = $self->load_db;
    my $bid = bundle_id($db, $bundle->name);
    if ($bid > 0) {
	return bundle_version($db, $bid);
    } else {
	return 0;
    }
}

sub ok_version {
    (@_ == 2) or confess "\tBUG";
    my ($self, $bundle) = @_;
    $self->sync_cache();	# be as up-to-date as possible...
    my $db = $self->load_db;
    my $bid = bundle_id($db, $bundle->name);
    if ($bid > 0) {
	return bundle_ok_version($db, $bid);
    } else {
	return 0;
    }
}

sub head_prop {
    (@_ == 3) or confess "\tBUG";
    my ($self, $bundle, $prop) = @_;
    $self->sync_cache();	# be as up-to-date as possible...
    my $db = $self->load_db;
    my $val = bundle_prop($db, bundle_id($db, $bundle->name), $prop);
    defined($val) or croak "Missing $prop property";
    return $val;
}

sub head_uri {
    (@_ == 3) or confess "\tBUG";
    my ($self, $bundle, $prop) = @_;
    $self->sync_cache();	# be as up-to-date as possible...
    my $db = $self->load_db;
    my $val = bundle_prop($db, bundle_id($db, $bundle->name), $prop);
    defined($val) or croak "Missing $prop property";
    return uri_string($db, $val);
}

sub ok_prop {
    (@_ == 3) or confess "\tBUG";
    my ($self, $bundle, $prop) = @_;
    $self->sync_cache();	# be as up-to-date as possible...
    my $db = $self->load_db;
    my $val = bundle_ok_prop($db, bundle_id($db, $bundle->name), $prop);
    defined($val) or croak "Missing $prop property";
    return $val;
}

sub graphs {
    (@_ == 2) or confess "\tBUG";
    my ($self, $bundle) = @_;
    $self->sync_cache();	# be as up-to-date as possible...
    my $db = $self->load_db;
    return bundle_graphs($db, bundle_id($db, $bundle->name));
}

# Note that this one does I<not> call ->sync_cache().
sub loaded_ok {
    (@_ == 3) or confess "\tBUG";
    my ($self, $bundle, $path) = @_;
    my $db = $self->load_db;
    return bundle_file_loaded_ok($db,
				 bundle_id($db, $bundle->name),
				 $bundle->version,
				 $path);
}

# Note that this does I<not> call ->sync_cache() either.
sub cleared_ok {
    (@_ == 2) or confess "\tBUG";
    my ($self, $bundle) = @_;
    my $db = $self->load_db;
    return bundle_graph_cleared_ok($db,
				   bundle_id($db, $bundle->name),
				   $bundle->version);
}

sub find_bundle {
    (@_ == 2) or confess "\tBUG";
    my ($self, $name) = @_;
    my $cache = $self->{bundle_cache};
    if (exists($cache->{$name})) {
	return $cache->{$name};
    }
    my $dir = $self->config_path("bundle_dir");
    my $path = "$dir/$name";
    unless (-d $path) { return 0 }
    my $bundle = new RDFHerd($path);
    unless ($name eq $bundle->name) {
	die "$path isn't a bundle named $name\n";
    }
    $cache->{$name} = $bundle;
    return $bundle;
}

sub check_notices_read {
    (@_ == 2) or confess "\tBUG";
    my ($self, $name) = @_;
    for my $x (@{$self->config_list("notices_read")}) {
	return 1 if ($x eq $name);
    }
    return 0;
}

sub test_name ($$) {
    my ($self, $val) = @_;
    return lc($val) eq lc($self->server_name);
}

sub make_test_version (&) {
    my ($op) = @_;
    return sub ($$) {
	my ($self, $val) = @_;
	return &$op($self->server_version,
		    $self->canonicalize_server_version($val));
    }
}

my %tests = (
    name => \&test_name,
    le => make_test_version(sub { $_[0] le $_[1] }),
    lt => make_test_version(sub { $_[0] lt $_[1] }),
    ge => make_test_version(sub { $_[0] ge $_[1] }),
    gt => make_test_version(sub { $_[0] gt $_[1] }),
    eq => make_test_version(sub { $_[0] eq $_[1] }),
    ne => make_test_version(sub { $_[0] ne $_[1] }),
    );

sub test_conditional {
    (@_ == 2) or confess "\tBUG";
    my ($self, $cond) = @_;
    for my $key (keys(%$cond)) {
	my $proc = $tests{$key};
	return 0 if ($proc and not &$proc($self, $cond->{$key}));
    }
    return 1;
}

# Don't checkpoint more than once every 15 minutes, otherwise when loading
# lots of small files, the overhead of checkpointing starts to get
# noticable!
my $checkpoint_interval = [0, 15 * 60 * 1000];

# Returns true if we really did begin, false if we are continuing.
sub begin_update_bundle {
    (@_ == 4) or confess "\tBUG";
    my ($self, $bundle, $graph, $base) = @_;
    my $log = $self->load_log;
    my ($d, $m) = mjdtime();
    $self->{next_checkpoint} = [mjdtime_add([$d, $m], $checkpoint_interval)];
    $self->{prev_graph} = $graph;
    $self->{prev_base} = $base;
    my $now_updating = $self->now_updating;
    if ($now_updating) {
	unless ($bundle == $now_updating) {
	    croak "Already updating ", $now_updating->name;
	}
	$log->write({
	    T		=> "$d/$m",
	    OP		=> "STEP:RESET",
	    GRAPH	=> $graph,
	    BASE	=> $base,
	});
	return 0;
    } else {
	$log->write({
	    T		=> "$d/$m",
	    OP		=> "BEGIN:UPDATE_BUNDLE",
	    BUNDLE	=> $bundle->name,
	    VERSION	=> $bundle->version,
	    GRAPH	=> $graph,
	    BASE	=> $base,
	    PATH	=> $bundle->path,
	});
	$self->{now_updating} = $bundle;
	return 1;
    }
}

# This step only makes sense I<before> all steps that might create graph
# structure.  It is the caller's responsibility to enforce that.
sub clear_update_bundle {
    (@_ == 2) or confess "\tBUG";
    my ($self, $bundle) = @_;
    unless ($bundle == $self->now_updating) {
	croak "Unexpected clear step for ", $bundle->name;
    }
    # Read the graphs I<before> sending any updates to the database:
    my $graphs = $self->graphs($bundle);
    my $log = $self->load_log;
    my ($d, $m) = mjdtime();
    $log->write({
	T	=> "$d/$m",
	OP	=> "STEP:CLEAR",
    });
    $log->sync();
    for my $graph (@{$graphs}) {
	$self->clear_graph($graph);
    }
}

sub step_update_bundle {
    (@_ == 7) or confess "\tBUG";
    my ($self, $bundle, $type, $relpath, $path, $graph, $base) = @_;
    unless ($bundle == $self->now_updating) {
	croak "Unexpected load step for ", $bundle->name;
    }
    my $log = $self->load_log;
    my $op = "STEP:ALSO";
    my ($d, $m) = mjdtime();
    if (mjdtime_cmp([$d, $m], $self->{next_checkpoint}) > 0) {
	$self->checkpoint();
	$op = "STEP:LOAD";
	$self->{next_checkpoint} =
	    [mjdtime_add([$d, $m], $checkpoint_interval)];
    }
    my $hr = {
	T	=> "$d/$m",
	OP	=> $op,
	TYPE	=> $type,
	PATH	=> $relpath,
    };
    if ($graph ne $self->{prev_graph} or $base ne $self->{prev_base}) {
	$hr->{GRAPH} = $graph;
	if ($base ne $graph) {
	    $hr->{BASE} = $base;
	}
	$self->{prev_graph} = $graph;
	$self->{prev_base} = $base;
    }
    $log->write($hr);
    $log->sync();
    unless ($self->{skip_load_file}) {
	$self->load_file($type, $path, $graph, $base);
    }
}

sub end_update_bundle {
    (@_ == 3) or confess "\tBUG";
    my ($self, $bundle, $abandon) = @_;
    unless ($bundle == $self->now_updating) {
	croak "Unexpected update end for ", $bundle->name;
    }
    my $log = $self->load_log;
    my ($d, $m) = mjdtime();
    $self->checkpoint();
    $log->write({
	T	=> "$d/$m",
	OP	=> ($abandon ? "END:ABANDON" : "END"),
    });
    $self->sync_cache();
    $self->{now_updating} = 0;
}

sub define_update_bundle {
    (@_ == 5) or confess "\tBUG";
    my ($self, $bundle, $name, $handler, $value) = @_;
    unless ($bundle == $self->now_updating) {
	croak "Unexpected definition in ", $bundle->name;
    }
    my $log = $self->load_log;
    my ($d, $m) = mjdtime();
    $log->write({
	T	=> "$d/$m",
	OP	=> "STEP:DEFINE",
	NAME	=> $name,
	VALUE	=> $value,
	HANDLER	=> $handler,
    });
}

sub command_table {
    my ($self) = @_;
    my $tbl = hash_compose({
	pid => {
	    proc => \&cmd_pid,
	    doc => "Print the running server's pid.",
	},
	stop => {
	    proc => sub { exit($_[0]->stop) },
	    doc => "Stop the running server.",
	},
	status => {
	    proc => \&cmd_status,
	    doc => "Test whether the server is running or not.",
	},
	bundle_status => {
	    proc => \&cmd_bundle_status,
	    usage => "[--all] <bundle> ...",
	    options => {
		"all" => $self->{opt_all},
	    },
	    maxargs => '*',
	    doc => "Summarize the status of loaded bundles of RDF.\n\nIf --all is specified, all of the bundles that the specified bundles depend upon are considered as well.  (The output in this mode can be confusing...)",
	},
	bundle_update => {
	    proc => \&cmd_bundle_update,
	    usage => "[--all] <bundle> ...",
	    options => {
		"all" => $self->{opt_all},
	    },
	    maxargs => '*',
	    doc => "Update bundles of RDF to the most recent version.  If --all is specified, all of the bundles that the specified bundles depend upon are updated as well.",
	},
	abandon_update => {
	    proc => \&cmd_abandon_update,
	    doc => "Abandon an interrupted update.\n\nIn effect this marks the current version of the partly-loaded bundle as broken.  After abandoning an update, you will not be able to update the broken bundle (or any bundle that depends on it) until you obtain a newer version of the broken bundle.",
	},
	continue_update => {
	    proc => \&cmd_continue_update,
	    doc => "Continue an interrupted update.",
	},
	run_script => {
	    proc => \&cmd_run_script,
	    usage => "<path>",
	    args => 1,
	    doc => "Run an arbitrary script.",
	},
	restart => {
	    proc => \&cmd_restart,
	    usage => "[--pidfile <path>]",
	    options => {
		"pidfile=s" => $self->{system_pid_file},
	    },
	    doc => "Stop and then restart the server.",
	},
	try_restart => {
	    proc => \&cmd_try_restart,
	    usage => "[--pidfile <path>]",
	    options => {
		"pidfile=s" => $self->{system_pid_file},
	    },
	    doc => "If the server is running, stop and then restart it.",
	},
	force_reload => {
	    proc => \&cmd_force_reload,
	    usage => "[--pidfile <path>]",
	    options => {
		"pidfile=s" => $self->{system_pid_file},
	    },
	    doc => "If the server is running, reload it in the best way.",
	},
	dump_db => {
	    proc => \&cmd_dump_db,
	    doc => "Dump the load database in an unfriendly format.\n\nUseful for dubugging.",
	},
	load_stats => {
	    proc => \&cmd_load_stats,
	    doc => "Generate statistics about load performance.",
	},
	change_password => {
	    proc => \&cmd_change_password,
	    doc => "Change the password for accessing the server.",
	},
	prepare_for_initial_load => {
	    proc => \&cmd_prepare_for_initial_load,
	    doc => "Prepare a fresh server before loading any data.",
	},
    }, $self->SUPER::command_table);
    if ($self->can("cmd_reload")) {
	$tbl->{reload} = {
	    proc => sub { $_[0]->cmd_reload },
	    doc => "Ask the running server to reload itself.",
	};
    }
    return $tbl;
}

sub cmd_pid {
    my ($self) = @_;
    my $pid = $self->pid;
    if ($pid <= 0) {
	exit(1);
    } else {
	print "$pid\n";
	return 'OK';
    }
}

sub stop {
    my ($self) = @_;
    $self->check_uid_write;
    my $pid = $self->pid;
    if ($pid <= 0) {
	return 0;
    } elsif (1 == kill(SIGTERM, $pid)) {
	$self->rm_pid;
	return 0;
    } else {
	$self->rm_pid;
	return 7;		# per LSB...
    }
}

sub status {
    my ($self) = @_;
    # ->check_uid_read is used here because although we only need read
    # access to the database, the following call to kill() will still fail
    # unless we are running with the correct UID.
    $self->check_uid_read;
    my $pid = $self->pid;
    if ($pid <= 0) {
	return 3;		# per LSB...
    } elsif (1 == kill(0, $pid)) {
	return 0;
    } else {
	return 1;		# per LSB...
    }
}

sub cmd_status {
    my $rv = $_[0]->status;
    if ($rv) {
	print "The server is not running.\n";
    } else {
	print "The server is running.\n";
    }
    exit($rv);
}

sub cmd_restart {
    my ($self) = @_;
    $self->stop;
    sleep(3);
    return $self->cmd_start;
}

# If the server's running, stop and restart it -- this is what LSB expects
# for "try-restart":
sub cmd_try_restart {
    my ($self) = @_;
    if ($self->status == 0) {
	return $self->cmd_restart;
    } else {
	return 'OK';
    }
}

# If a server defines a C<cmd_reload> method, it should do I<nothing> if the
# server isn't actually running -- this is what LSB expects for "reload".
# It should also return 'OK'.

# I changed a config file, and I know that the server is running:
# (Many init.d scripts incorrectly do this for "force-reload".)
sub cmd_need_reload {
    my ($self) = @_;
    if ($self->can("cmd_reload")) {
	return $self->cmd_reload;
    } else {
	return $self->cmd_restart;
    }
}

# I changed a config file, but I don't know whether the server is (or
# should be) running or not -- this is what LSB expects for "force-reload":
sub cmd_force_reload {
    my ($self) = @_;
    if ($self->status == 0) {
	return $self->cmd_need_reload;
    } else {
	return 'OK';
    }
}

# I changed a config file, and I want the server to be running:
sub cmd_reload_start {
    my ($self) = @_;
    if ($self->status == 0) {
	return $self->cmd_need_reload;
    } else {
	return $self->cmd_start;
    }
}

sub cmd_bundle_status {
    my ($self, undef, @bundle_names) = @_;
    unless ($self->initialized) {
	print "The server has not been initialized.\n";
	print "You need to issue the prepare_for_initial_load command.\n";
    }
    my $now_updating = $self->now_updating;
    if ($now_updating) {
	my $name = $now_updating->name;
	print <<"EOM"
The server was interrupted while updating $name.  You will need
to either continue or abandon that update before you can update anything
else.
EOM
;
    }
    my ($bundle, $status);
    my $all_ptr = $self->{opt_all};
    for my $name (@bundle_names) {
	$bundle = $self->find_bundle($name);
	if ($bundle) {
	    $status = $bundle->update_status($self, $$all_ptr);
	} else {
	    $status = "no such bundle";
	}
	print "$name:\t$status\n";
    }
    'OK'
}

sub cmd_bundle_update {
    my ($self, undef, @bundle_names) = @_;
    unless ($self->initialized) {
	print STDERR "The server has not been initialized.\n";
	print STDERR "You need to issue the prepare_for_initial_load command.\n";
	exit 1;
    }
    $self->check_uid_write;
    if (my $err = $self->open_connection()) { die "$err\n"; }
    my $bundle = $self->now_updating;
    if ($bundle) {
	my $name = $bundle->name;
	print <<"EOM"
The server was interrupted while updating $name.  You will need
to either continue or abandon that update before you can update anything
else.  If you like, I can try to finish that interrupted update before
proceeding with the updates you requested.
EOM
;
	if (yes_or_no("Continue interrupted update of $name?")) {
	    $bundle->continue_update($self);
	} else {
	    print STDERR "Must continue or abandon update of $name.\n";
	    exit 1;	    
	}
    }
    my $all_ptr = $self->{opt_all};
    for my $name (@bundle_names) {
	$bundle = $self->find_bundle($name);
	if ($bundle) {
	    $bundle->update($self, $bundle->version, $$all_ptr, 0);
	} else {
	    print STDERR "no such bundle: $name\n";
	    exit 1;
	}
    }
    $self->close_connection();
    'OK'
}

sub cmd_abandon_update {
    my ($self) = @_;
    $self->check_uid_write;
    my $bundle = $self->now_updating;
    unless ($bundle) {
	print STDERR "No update in progress\n";
	exit 1;
    }
    $bundle->abandon_update($self);
    'OK'
}

sub cmd_continue_update {
    my ($self) = @_;
    $self->check_uid_write;
    my $bundle = $self->now_updating;
    unless ($bundle) {
	print STDERR "No update in progress\n";
	exit 1;
    }
    if (my $err = $self->open_connection()) { die "$err\n"; }
    $bundle->continue_update($self);
    $self->close_connection();
    'OK'
}

sub cmd_dump_db {
    my $db = $_[0]->load_db;	# this will cause the log to be read...
    for my $k (sort(keys(%$db))) {
	print "$k => ", $db->{$k}, "\n";
    }
    'OK'
}

use constant {
    MSPD => 24 * 60 * 60 * 1000, # msecs per day
};

sub cmd_load_stats {
    my $db = $_[0]->load_db;	# this will cause the log to be read...
    my $bcount = $db->{BUNDLE_COUNT};
    my @stats = ();
    my $total_time = 0;
    for (my $bid = 1; $bid <= $bcount; $bid++) {
	my $version = bundle_ok_version($db, $bid);
	if ($version > 0) {
	    my ($d0, $t0) = split('/', bundle_ok_prop($db, $bid, 'TBEGIN'));
	    my ($d1, $t1) = split('/', bundle_ok_prop($db, $bid, 'TEND'));
	    my $time = ((($d1 - $d0) * MSPD) + $t1) - $t0;
	    $total_time += $time;
	    push(@stats, {
		bid => $bid,
		version => $version,
		time => $time,
		name => bundle_name($db, $bid),
		 });
	}
    }
    for my $x (sort { $b->{time} <=> $a->{time} } @stats) {
	my $time = $x->{time};
	my $percent = do {
	    no integer;
	    ($time * 100) / $total_time;
	};
	printf("%10d (%5.2f%%) %s\n", $time, $percent, $x->{name});
    }
    printf("%10d Total milliseconds\n", $total_time);
    'OK'
}

sub cmd_change_password {
    my ($self) = @_;
    $self->check_uid_write;
    $self->load_password("Old password for");
    if (my $err = $self->open_connection()) { die "$err\n"; }
    my $pass = password_read("New password");
    my $again = password_read("New password again");
    unless ($pass eq $again) {
	print STDERR "New passwords don't match -- password unchanged.\n";
	exit 1;
    }
    $self->change_password($pass);
    $self->close_connection();
    'OK'
}

sub cmd_prepare_for_initial_load {
    my ($self) = @_;
    $self->check_uid_write;
    my $log = $self->load_log;
    if (my $err = $self->open_connection()) { die "$err\n"; }
    $self->prepare_for_initial_load();
    $self->close_connection();
    my ($d, $m) = mjdtime();
    # replaces ACTION:INITIALIZE
    $log->write({
	T	=> "$d/$m",
	OP	=> "ACTION:CHECK_VERSION",
	MIN	=> 3,
	MAX	=> 3,
    });
    $self->sync_cache();
    'OK'
}

sub cmd_run_script {
    my ($self, undef, $path) = @_;
    $self->check_uid_write;
    if (my $err = $self->open_connection()) { die "$err\n"; }
    $self->load_file("script", $path, "null:", "null:");
    $self->close_connection();
    'OK'
}

1;
__END__

# Local Variables:
# mode: Perl
# End:
