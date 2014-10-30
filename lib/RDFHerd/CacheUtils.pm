# Utilities for maintaining the RDFHerd cache
#
# Copyright © 2008-2010  Creative Commons Corp.
#
# $Id: CacheUtils.pm 3580 2010-08-18 22:51:54Z bawden $

package RDFHerd::CacheUtils;

use 5.008_005;
use strict;
use integer;
use Carp;
use Exporter;
use RDFHerd::Utils qw(check_version);
#use English '-no_match_vars';

our (@ISA, $VERSION, @EXPORT_OK);
@ISA = qw(Exporter);
$VERSION = 1.18_01;
@EXPORT_OK = qw(
    cache_init scratch_init cache_fold
    bundle_id bundle_name
    bundle_graphs
    uri_id uri_string
    bundle_version bundle_ok_version
    bundle_prop bundle_ok_prop
    bundle_file_loaded_ok
    bundle_graph_cleared_ok
    transaction_in_progress
    server_initialized
    );

# These routines usually work with bindle IDs.  Occasionally a bundle name
# will appear.  But never a bundle object.

# Remember, by the rules of Log.pm, if we crash while replaying the log,
# the cache will be reconstructed from scratch!  So the only real issue is
# access to the cache for I<readers> who can't replay the log.  For their
# benefit, we carefully order our writes so that they can always recover a
# consistent picture.

# Procedures on this page are safe for read-only callers. 

# Bundle ID 0 is never used, so 0 means not found:
sub bundle_id ($$) {
    my ($db, $name) = @_;
    return $db->{"BUNDLE_ID $name"} || 0;
}

sub bundle_name ($$) { $_[0]->{"NAME " . $_[1]} }
sub bundle_version ($$) { $_[0]->{"VERSION " . $_[1]} }

my %prop_default = (
    STATE	=> 'OK',
    );

sub bundle_version_prop ($$$$) {
    my ($db, $bid, $version, $prop) = @_;
    if ($version > 0) {
	return $db->{"$prop $bid $version"};
    } else {
	return $prop_default{$prop};
    }
}

sub bundle_prop ($$$) {
    my ($db, $bid, $prop) = @_;
    return bundle_version_prop($db, $bid, bundle_version($db, $bid), $prop);
}

sub bundle_ok_version ($$) {
    my ($db, $bid) = @_;
    my $version = bundle_version($db, $bid);
    until (bundle_version_prop($db, $bid, $version, 'STATE') eq 'OK') {
	$version = bundle_version_prop($db, $bid, $version, 'PREV');
    }
    return $version;
}

sub bundle_ok_prop ($$$) {
    my ($db, $bid, $prop) = @_;
    return bundle_version_prop($db, $bid, bundle_ok_version($db, $bid), $prop);
}

sub bundle_file_loaded_ok ($$$$) {
    my ($db, $bid, $version, $path) = @_;
    my $status = $db->{"$bid $path"};
    if (defined($status)) {
	return $status =~ m(^$version:.*:OK\z);
    } else {
	return 0;
    }
}

sub bundle_graph_cleared_ok ($$$) {
    my ($db, $bid, $version) = @_;
    my $status = $db->{"CLEARED $bid $version"};
    if (defined($status)) {
	return $status =~ m(:OK\z);
    } else {
	return 0;
    }
}

# Returns an error string if there was an error, else returns a hash ref.
# Unused, unexported
sub get_definition ($$) {
    my ($db, $name) = @_;
    my $bid = $db->{"DEF_SOURCE $name"};
    unless (defined($bid)) {
	return "$name has never been defined.";
    }
    my $bname = bundle_name($db, $bid);
    my $bversion = bundle_version($db, $bid);
    my $state = bundle_version_prop($db, $bid, $bversion, 'STATE');
    unless ($state eq 'OK') {
	return "$name is unavailable because $bname is currently $state.";
    }
    my $version = $db->{"DEF_VERSION $name"} or die;
    unless ($version == $bversion) {
	return "$name was defined in $bname version $version,\nbut it is no longer defined in version $bversion.";
    }
    my $handler = $db->{"DEF_HANDLER $name"} or die;
    my $value = $db->{"DEF_VALUE $name"} or die;
    # XXX caller should check that the returned bundle is actually listed
    # XXX among its dependencies!
    return {
	NAME => $name,
	VALUE => $value,
	HANDLER => $handler,
	BUNDLE => $bname,
	VERSION => $version,
    };
}

# Unused, unexported
sub bundle_file_status ($$$) {
    my ($db, $bid, $path) = @_;
    my $status = $db->{"$bid $path"};
    if (defined($status)) {
	my ($version, $t, $type, $state) = split(':', $status);
	return {
	    PATH => $path,
	    STATE => $state,
	    T => $t,
	    VERSION => $version,
	    TYPE => $type,
	};
    } else {
	return {
	    PATH => $path,
	    STATE => 'UNKNOWN',	    
	};
    }
}

# $db->{IN_PROGRESS} is really just a cache of a more complicated check.
# If it is TRUE, that might be a lie, so in that case we have to do the
# real check.  But if it is FALSE, we can quickly answer FALSE.
# TRUE is returned as the ID of the bundle being updated.
sub transaction_in_progress ($) {
    my ($db) = @_;
    unless ($db->{IN_PROGRESS}) {
	return 0;
    }
    my $bid = $db->{NOW_UPDATING};
    defined($bid) or die;
    if (bundle_prop($db, $bid, 'STATE') eq 'UPDATING') {
	return $bid;
    }
    return 0;
}

sub server_initialized ($) {
    my ($db) = @_;
    return $db->{INITIALIZED};
}

sub cache_init ($) {
    my ($db) = @_;
    %$db = (
	INITIALIZED => 0,
	BUNDLE_COUNT => 0,
	URI_COUNT => 0,
	IN_PROGRESS => 0,
	"VERSION 0" => 0,
	"NAME 0" => "<Null Bundle>",
	"URI_ID null:" => 0,
	"URI_ID <unused>" => 0,	# backwards compatibility...
	"URI_STRING 0" => "null:",
	);
}

sub action_initialize ($$$$) {
    my ($hr, $db, $scratch, $t) = @_;
    if (transaction_in_progress($db)) {
	croak "Transaction in progress";
    }
    if ($db->{INITIALIZED}) {
	croak "Server already initialized?";
    }
    $db->{INITIALIZED} = 1;
}

sub action_check_version ($$$$) {
    my ($hr, $db, $scratch, $t) = @_;
    if (transaction_in_progress($db)) {
	croak "Transaction in progress";
    }
    if ($db->{INITIALIZED}) {
	croak "Server already initialized?";
    }
    my $vmin = $hr->{MIN} or croak "Missing min version";
    my $vmax = $hr->{MAX} or croak "Missing max version";
    $db->{INITIALIZED} = check_version(1, 3, "Loaded.log", $vmin, $vmax);
}

sub uri_id ($$) {
    my ($db, $uri) = @_;
    my $uid = $db->{"URI_ID $uri"};
    return $uid if (defined($uid));
    $uid = $db->{URI_COUNT};
    defined($uid) or die;
    $uid++;
    $db->{URI_COUNT} = $uid;
    $db->{"URI_STRING $uid"} = $uri;
    $db->{"URI_ID $uri"} = $uid; # Here we commit
    return $uid;
}

sub uri_string ($$) { $_[0]->{"URI_STRING " . $_[1]} }

sub claim_graph ($$$) {
    my ($db, $bid, $gid) = @_;
    return if ($gid == 0);	# null belongs to everybody and nobody
    my $obid = $db->{"GRAPH_BUNDLE $gid"} || 0;
    return if ($obid == $bid);
    if ($obid) {
	my $obname = bundle_name($db, $obid);
	my $bname = bundle_name($db, $bid);
	my $gname = uri_string($db, $gid);
	croak "$bname can't claim $gname -- owned by $obname";
    }
    $db->{"GRAPH_BUNDLE $gid"} = $bid;
}

sub bundle_graphs ($$) {
    my ($db, $bid) = @_;
    my @graphs = ();
    my $gid = $db->{URI_COUNT};
    while ($gid > 0) {
	# Not all URI's are graphs, but most of them are, so this is fast
	# enough...
	if ($db->{"GRAPH_BUNDLE $gid"} == $bid) {
	    unshift(@graphs, uri_string($db, $gid));
	}
	$gid--;
    }
    return \@graphs;
}

sub release_graphs ($$) {
    my ($db, $bid) = @_;
    my $gid = $db->{URI_COUNT};
    while ($gid > 0) {
	# Not all URI's are graphs, but most of them are, so this is fast
	# enough...
	if ($db->{"GRAPH_BUNDLE $gid"} == $bid) {
	    $db->{"GRAPH_BUNDLE $gid"} = 0;
	}
	$gid--;
    }
}

sub bundle_intern ($$) {
    my ($db, $name) = @_;
    my $bid = $db->{"BUNDLE_ID $name"};
    return $bid if (defined($bid));
    $bid = $db->{BUNDLE_COUNT};
    defined($bid) or die;
    $bid++;
    $db->{BUNDLE_COUNT} = $bid;
    $db->{"NAME $bid"} = $name;
    $db->{"VERSION $bid"} = 0;
    $db->{"BUNDLE_ID $name"} = $bid; # Here we commit
    return $bid;
}

sub begin_update ($$$$) {
    my ($hr, $db, $scratch, $t) = @_;
    if (transaction_in_progress($db)) {
	croak "Transaction already in progress";
    }
    unless ($db->{INITIALIZED}) {
	croak "Apparently prehistoric Loaded.log found -- log format error";
    }
    my $bname = $hr->{BUNDLE} or croak "Missing bundle name";
    my $version = $hr->{VERSION} or croak "Missing version";
    my $graph = $hr->{GRAPH} or croak "Missing graph URI";
    my $base = $hr->{BASE} or croak "Missing base URI";
    my $path = $hr->{PATH} or croak "Missing path";

    my $bid = bundle_intern($db, $bname);
    my $gid = uri_id($db, $graph);
    my $bsid = uri_id($db, $base);
    my $oversion = bundle_version($db, $bid);
    unless ($version > $oversion) {
	confess "$bname version $version not newer than version $oversion\n\tBUG";
    }
    my $ix = "$bid $version";
    claim_graph($db, $bid, $gid);
    $db->{"GRAPH $ix"} = $gid;
    $db->{"BASE $ix"} = $bsid;
    $db->{"PATH $ix"} = $path;
    $db->{"PREV $ix"} = $oversion;
    $db->{"STATE $ix"} = 'UPDATING';
    $db->{"TBEGIN $ix"} = $t;

    if (bundle_prop($db, $bid, 'STATE') eq 'UPDATING') {
	die "$bname version $oversion still UPDATING";
    }
    $db->{NOW_UPDATING} = $bid;
    $db->{IN_PROGRESS} = 1;
    # IN_PROGRESS is now a lie.  But that's OK as long as it is TRUE.  See
    # transaction_in_progress().
    $db->{"VERSION $bid"} = $version; # Here we commit

    $scratch->{BUNDLE_ID} = $bid;
    $scratch->{INDEX} = $ix;
    $scratch->{GRAPH_ID} = $gid;
    $scratch->{BASE_ID} = $bsid;
    $scratch->{PENDING} = [];
}

sub scratch_init ($$) {
    my ($db, $scratch) = @_;
    my $bid = transaction_in_progress($db);
    if ($bid) {
	my $version = $db->{"VERSION $bid"};
	my $ix = "$bid $version";
	$scratch->{BUNDLE_ID} = $bid;
	$scratch->{INDEX} = $ix;
	$scratch->{GRAPH_ID} = $db->{"GRAPH $ix"};
	$scratch->{BASE_ID} = $db->{"BASE $ix"};
	$scratch->{PENDING} = [];
    }
}

sub graph_select ($$$) {
    my ($hr, $db, $scratch) = @_;
    my $graph = $hr->{GRAPH} or croak "Missing graph URI";
    my $base = $hr->{BASE} || $graph;
    my $gid = uri_id($db, $graph);
    my $bsid = uri_id($db, $base);
    if ($gid != $scratch->{GRAPH_ID} or $bsid != $scratch->{BASE_ID}) {
	my $bid = $scratch->{BUNDLE_ID};
	my $ix = $scratch->{INDEX};
	claim_graph($db, $bid, $gid);
	$db->{"GRAPH $ix"} = $gid;
	$db->{"BASE $ix"} = $bsid;
	$scratch->{GRAPH_ID} = $gid;
	$scratch->{BASE_ID} = $bsid;
    }
}

sub step_finish ($$$) {
    my ($db, $scratch, $state) = @_;
    for my $ix (@{$scratch->{PENDING}}) {
	$db->{$ix} =~ s(:\w+\z)(:$state);
    }
    $scratch->{PENDING} = [];
}

sub step_reset ($$$$) {
    my ($hr, $db, $scratch, $t) = @_;
    transaction_in_progress($db) or
	croak "No transaction in progress";
    unless ($db->{INITIALIZED} < 3) {
	graph_select($hr, $db, $scratch);
    }
    step_finish($db, $scratch, 'UNFINISHED');
}

sub step_clear ($$$$) {
    my ($hr, $db, $scratch, $t) = @_;
    my $bid = transaction_in_progress($db) or
	croak "No transaction in progress";
    my $gid = $scratch->{GRAPH_ID};
    # Release them all...
    release_graphs($db, $bid);
    # Then grab back the one we're about to write in:
    claim_graph($db, $bid, $gid);
    my $version = bundle_version($db, $bid);
    my $ix = "CLEARED $bid $version";
    $db->{$ix} = "$t:UPDATING";
    push(@{$scratch->{PENDING}}, $ix);
}

sub step_load ($$$$) {
    my ($hr, $db, $scratch, $t) = @_;
    my $bid = transaction_in_progress($db) or
	croak "No transaction in progress";
    unless ($hr->{OP} eq 'STEP:ALSO') {
	step_finish($db, $scratch, 'OK');
    }
    if ($hr->{GRAPH}) {
	graph_select($hr, $db, $scratch);
    }
    my $gid = $scratch->{GRAPH_ID};
    my $bsid = $scratch->{BASE_ID};
    my $version = bundle_version($db, $bid);
    my $type = $hr->{TYPE} or croak "Missing load type";
    my $path = $hr->{PATH} or croak "Missing path";
    my $ix = "$bid $path";
    $db->{$ix} = "$version:$gid:$bsid:$t:$type:UPDATING";
    push(@{$scratch->{PENDING}}, $ix);
}

# Since definitions are only used if the bundle they came from is 'OK', we
# don't have to be too careful about the order of writes here.  We I<do>
# write the DEF_SOURCE first so that any preexisting definition gets
# invalidated right away.  Note that the source bundle version number is
# recorded so that we can spot obsolete definitions.
sub step_define ($$$$) {
    my ($hr, $db, $scratch, $t) = @_;
    my $bid = transaction_in_progress($db) or
	croak "No transaction in progress";
    my $version = bundle_version($db, $bid);
    my $name = $hr->{NAME} or croak "Missing definition name";
    my $value = $hr->{VALUE} or croak "Missing definition value";
    my $handler = $hr->{HANDLER} or croak "Missing definition handler";
    $db->{"DEF_SOURCE $name"} = $bid;
    $db->{"DEF_VERSION $name"} = $version;
    $db->{"DEF_HANDLER $name"} = $handler;
    $db->{"DEF_VALUE $name"} = $value;
}

sub end_transaction ($$$$) {
    my ($hr, $db, $scratch, $t) = @_;
    my $bid = transaction_in_progress($db) or
	croak "No transaction in progress";
    my $state = ($hr->{OP} eq 'END' ? 'OK' : 'UNFINISHED');
    step_finish($db, $scratch, $state);
    my $version = bundle_version($db, $bid);
    my $ix = "$bid $version";
    $db->{"TEND $ix"} = $t;
    $db->{"STATE $ix"} = $state; # Here we commit
    # IN_PROGRESS is now a lie.  But that's OK as long as it is TRUE.  See
    # transaction_in_progress().
    $db->{IN_PROGRESS} = 0;	# Lie over
}

my %optable = (
    "ACTION:INITIALIZE"		=> \&action_initialize,
    "ACTION:CHECK_VERSION"	=> \&action_check_version,
    "BEGIN:UPDATE_BUNDLE"	=> \&begin_update,
    "STEP:ALSO"			=> \&step_load,
    "STEP:LOAD"			=> \&step_load,
    "STEP:RESET"		=> \&step_reset,
    "STEP:DEFINE"		=> \&step_define,
    "STEP:CLEAR"		=> \&step_clear,
    "END"			=> \&end_transaction,
    "END:ABANDON"		=> \&end_transaction,
    );

sub cache_fold ($$$) {
    my ($hr, $db, $scratch) = @_;
    my $t = $hr->{T} or croak "Missing timestamp";
    my $op = $hr->{OP} or croak "Missing opcode";
    my $proc = $optable{$op};
    if (defined($proc)) {
	&$proc($hr, $db, $scratch, $t);
    } else {
	croak "Unhandled OP: $op";
    }
}

1;
__END__

# Local Variables:
# mode: Perl
# End:
