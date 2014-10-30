# A "bundle" is a directory full of assorted RDF files.
#
# Copyright © 2008-2010  Creative Commons Corp.
#
# $Id: Bundle.pm 3580 2010-08-18 22:51:54Z bawden $

# Should we check for circular dependencies somewhere?

package RDFHerd::Bundle;

use 5.008_005;
use strict;
use integer;
use Carp;
use RDFHerd::Utils qw(check_class_version foreach_file ordered_keys
		      hash_compose display);
use RDFHerd;
#use Cwd qw(abs_path);
#use English '-no_match_vars';
#use Fcntl qw(O_RDONLY);
#use FileHandle;
#use POSIX qw();

our (@ISA, $VERSION);
@ISA = qw(RDFHerd);
$VERSION = 1.18_01;

sub _new {
    my ($class, $class_name, $path, $cfg) = @_;
    check_class_version(1, 4, $path, $cfg);
    my $self = {
	class_name => "RDF Bundle",
	path => $path,
	config => $cfg,
    };
    bless($self, $class);
    return $self;
}

sub initialize {
    my ($self) = @_;
    $self->SUPER::initialize();
    $self->{name} = $self->config_string("name");
    $self->{version} = $self->config_string("version");
}

my %type_table = (
    "n3"	=> "ttl",
    "n3.bz"	=> "ttlbz",
    "n3.bz2"	=> "ttlbz",
    "n3.gz"	=> "ttlgz",
    "nt"	=> "ttl",
    "nt.bz"	=> "ttlbz",
    "nt.bz2"	=> "ttlbz",
    "nt.gz"	=> "ttlgz",
    "owl"	=> "rdf",
    "owl.bz"	=> "rdfbz",
    "owl.bz2"	=> "rdfbz",
    "owl.gz"	=> "rdfgz",
    "rdf"	=> "rdf",
    "rdf.bz"	=> "rdfbz",
    "rdf.bz2"	=> "rdfbz",
    "rdf.gz"	=> "rdfgz",
    "rdfs"	=> "rdf",
    "rdfs.bz"	=> "rdfbz",
    "rdfs.bz2"	=> "rdfbz",
    "rdfs.gz"	=> "rdfgz",
    "script"	=> "script",
    "sparql"	=> "sparql",
    "sql"	=> "sql",
    "ttl"	=> "ttl",
    "ttl.bz"	=> "ttlbz",
    "ttl.bz2"	=> "ttlbz",
    "ttl.gz"	=> "ttlgz",
    );

my %known_types = (
    rdf => 1,
    rdfgz => 1,
    script => 1,
    sparql => 1,
    sql => 1,
    ttl => 1,
    ttlbz => 1,
    ttlgz => 1,
    );

sub _file_type ($) {
    my ($name) = @_;
    if ($name =~ m(\.([a-z0-9]+(?:\.bz|\.bz2|\.gz)?\z))) {
	return $type_table{$1} || 0;
    }
    return 0;
}

sub _old_load_spec ($$$$$) {
    my ($bundle, $abspath, $relpath, $graph, $base) = @_;
    my $name = $bundle->name;
    my $spec = {
	abspath => $abspath,
	path => $relpath,
	graph => $graph,
	base => $base,
    };
    if (-d $abspath) {
	if ($graph eq "null:" and
	    foreach_file($abspath, "", sub { _file_type($_[1]) })) {
	    die "$relpath in $name has no specified graph.\n";
	}
	$spec->{IS_DIR} = 1;
    } elsif (-f $abspath) {
	if ($graph eq "null:") {
	    die "$relpath in $name has no specified graph.\n";
	}
	$spec->{type} = _file_type($relpath) ||
	    die "Unknown type for $relpath in $name\n";
    } else {
	die "$relpath in $name does not name a file or a directory.\n";
    }
    push(@{$bundle->{load_specs}}, $spec);
}

sub _new_load_spec ($$$$$) {
    my ($bundle, $spec, $path, $graph, $base) = @_;
    my $name = $bundle->name;
    my $relpath = $spec->{path};
    my $abspath = "$path/$relpath";
    my $for = $spec->{for};
    if ($for) {
	unless (ref($for) eq 'HASH' and
		$for->{CONSTRUCTOR} eq 'LOADCONDITIONAL') {
	    die "Bad load conditional for $relpath in $name.\n";
	}
    }
    $graph = $spec->{graph} || $graph;
    $base = $spec->{base} || $spec->{graph} || $base;
    if ($spec->{IS_DIR}) {
	unless (-d $abspath) {
	    die "$relpath in $name does not name a directory.\n";
	}
	if ($graph eq "null:" and
	    foreach_file($abspath, "", sub { _file_type($_[1]) })) {
	    die "$relpath in $name has no specified graph.\n";
	}
    } else {
	unless (-f $abspath) {
	    die "$relpath in $name does not name a regular file.\n";
	}
	if ($graph eq "null:") {
	    die "$relpath in $name has no specified graph.\n";
	}
	my $type = $spec->{type};
	if (not $type) {
	    $spec->{type} = _file_type($relpath) ||
		die "Unknown type for $relpath in $name\n";
	} elsif (not $known_types{$type}) {
	    $spec->{type} = _file_type(".$type") ||
		die "Unknown type '$type' for $relpath in $name\n";
	}
    }
    $spec->{abspath} = $abspath;
    $spec->{graph} = $graph;
    $spec->{base} = $base;
    push(@{$bundle->{load_specs}}, $spec);
}

# Check well-formedness and canonicalize the load specs, cache the results,
# and return them.
sub load_specs {
    my ($self) = @_;
    my $load_specs = $self->{load_specs};
    return $load_specs if ($load_specs);
    $self->{load_specs} = [];
    my $name = $self->name;
    my $path = $self->path;
    my $config = $self->config;
    my $class_version = $config->{class_version};
    my $graph = $config->{graph} || "null:";
    my $base = $config->{base} || $graph;
    my $load = $config->{load};
    my $load_graphs = $config->{load_graphs};
    if ($load) {
	if ($load_graphs) {
	    die "$name has both load and load_graphs.\n";
	}
	for my $x (@{$load}) {
	    if (not ref($x)) {
		_old_load_spec($self, "$path/$x", $x, $graph, $base);
	    } elsif (ref($x) eq 'HASH') {
		unless ($x->{CONSTRUCTOR} eq 'LOADSPEC' and $x->{path}) {
		    die "$name has a malformed hash in its load list.\n"
		}
		if ($class_version < 4) {
		    die "$name has a new-style load specification "
			. "in its load list, "
			. "but class_version is $class_version "
			. "(it must be at least 4).\n";
		}
		_new_load_spec($self, $x, $path, $graph, $base);
	    } else {
		die "$name has a non-hash reference in its load list.\n";
	    }
	}
    } elsif ($load_graphs) {
	if ($class_version < 3) {
	    die "$name uses load_graphs, "
		. "but class_version is $class_version "
		. "(it must be at least 3).\n";
	}
	my ($l, $h) = ordered_keys($load_graphs);
	for my $rp (@{$l}) {
	    my $g = $h->{$rp};
	    _old_load_spec($self, "$path/$rp", $rp, $g, $g);
	}
    } else {
	_old_load_spec($self, $path, "", $graph, $base);
    }
    return $self->{load_specs};
}

# Does all of the error checking needed for ->update().
sub cannot_update {
    (@_ == 4) or confess "\tBUG";
    my ($self, $server, $target, $all) = @_;
    my $path = $self->path;
    my $name = $self->name;
    my $version = $self->version;
    my $head_version = $server->head_version($self);
    my $head_state = $server->head_prop($self, 'STATE');
    if ($head_state eq 'OK') {
	if ($target <= $head_version) {
	    if ($all) {
		return $self->cannot_update_subbundles($server, $all);
	    } else {
		return 0;
	    }
	}
    } elsif ($head_state eq 'UNFINISHED') {
	unless ($version > $head_version) {
	    return "Update of $name version $head_version was abandoned.";
	}
    } elsif ($head_state eq 'UPDATING') {
	return "Update of $name must be continued or abandoned.";
    } else {
	confess "Bad state: $head_state\n\tBUG";
    }
    if ($version < $target) {
	return "$name version $target not available";
    }
    my $notices = $self->config->{notices};
    if ($notices) {
	unless ($server->check_notices_read($notices)) {
	    return "You haven't read $notices (check notices_read in your server config file).";
	}
    }
    my $whynot = $self->cannot_update_subbundles($server, $all);
    if ($whynot) { return $whynot }
    $self->load_specs;		# spot most syntax errors early...
    return 0;
}

sub cannot_update_subbundles {
    (@_ == 3) or confess "\tBUG";
    my ($self, $server, $all) = @_;
    my $path = $self->path;
    my $subbundles = $self->config->{subbundles} || {};
    (ref($subbundles) eq 'HASH') or
	(ref($subbundles) eq 'ARRAY') or
	die "subbundles (in $path) must be a hash or an array.\n";
    my ($bnames, $versions) = ordered_keys($subbundles);
    for my $bname (@$bnames) {
	my $bundle = $server->find_bundle($bname);
	unless ($bundle) { return "$bname not found" }
	my $bversion = $bundle->version;
	my $btarget = $versions->{$bname};
	if ($bversion < $btarget) {
	    return "$bname version $btarget not available";
	}
	$btarget = ($all ? $bversion : $btarget);
	my $whynot = $bundle->cannot_update($server, $btarget, $all);
	if ($whynot) { return $whynot }
    }
}

sub _update ($$$$);

sub update {
    (@_ == 5) or confess "\tBUG";
    my ($self, $server, $target, $all, $plan) = @_;
    my $name = $self->name;
    my $whynot = $self->cannot_update($server, $target, $all);
    if ($whynot) {
	die "Cannot update $name to version $target: $whynot\n";
    }
    if ($target <= $server->head_version($self) and
	'OK' eq $server->head_prop($self, 'STATE')) {
	if ($all) {
	    $self->update_subbundles($server, $all, $plan);
	}
    } else {
	$self->update_subbundles($server, $all, $plan);
	if ($plan) {
	    my $otarget = $plan->{$name} || 0;
	    if ($target > $otarget) { $plan->{$name} = $target }
	} else {
	    my $graph = $self->config->{graph} || "null:";
	    my $base = $self->config->{base} || $graph;
	    _update($self, $server, $graph, $base);
	}
    }
}

sub update_subbundles {
    (@_ == 4) or confess "\tBUG";
    my ($self, $server, $all, $plan) = @_;
    my $subbundles = $self->config->{subbundles} || {};
    my ($bnames, $versions) = ordered_keys($subbundles);
    for my $bname (@$bnames) {
	my $bundle = $server->find_bundle($bname);
	my $bversion = ($all ? $bundle->version : $versions->{$bname});
	$bundle->update($server, $bversion, $all, $plan);
    }
}

sub _update_load ($$$) {
    my ($bundle, $server, $spec) = @_;
}

sub _update ($$$$) {
    my ($bundle, $server, $graph, $base) = @_;
    print STDERR "Updating: ", $bundle->name, "\n";
    $server->begin_update_bundle($bundle, $graph, $base);

    my $no_clear_version = $bundle->config->{no_need_to_clear_version};
    my $ok_version = $server->ok_version($bundle);
    if ($no_clear_version and
	$ok_version > 0 and
	$ok_version < $no_clear_version and
	not $server->cleared_ok($bundle)) {
	$server->clear_update_bundle($bundle);
    }

    for my $spec (@{$bundle->load_specs}) {
	my ($cond, $relpath, $abspath, $g, $b) =
	    @{$spec}{qw(for path abspath graph base)};
	if (not $cond or $server->test_conditional($cond)) {
	    if ($spec->{IS_DIR}) {
		foreach_file($abspath, $relpath, sub {
		    my ($ap, $rp) = @_;
		    unless ($server->loaded_ok($bundle, $rp)) {
			my $t = _file_type($rp);
			if ($t) {
			    $server->step_update_bundle($bundle, $t,
							$rp, $ap,
							$g, $b);
			}
		    }
		    return 0;
		});
	    } else {
		unless ($server->loaded_ok($bundle, $relpath)) {
		    $server->step_update_bundle($bundle, $spec->{type},
						$relpath, $abspath,
						$g, $b);
		}
	    }
	}
    }

    my $export = $bundle->config->{export} || {};
    while (my ($name, $spec) = each(%$export)) {
	unless (ref($spec) eq 'ARRAY' and @$spec == 2) {
	    die "Bad export definition for $name.\n";
	}
	$server->define_update_bundle($bundle, $name, $spec->[0], $spec->[1]);
    }

    $server->end_update_bundle($bundle, 0);
    #print STDERR "Finished update: ", $bundle->name, "\n";
}

sub abandon_update {
    (@_ == 2) or confess "\tBUG";
    my ($self, $server) = @_;
    $server->end_update_bundle($self, 1);
}

sub continue_update {
    (@_ == 2) or confess "\tBUG";
    my ($self, $server) = @_;
    unless ($self->version == $server->head_version($self)) {
	my $name = $self->name;
	die <<"EOM"
The version of '$name' we were interrupted from loading is not
the same as the current source.  Your best option is probably to abandon
that prior update and then do a fresh update to the new version.
EOM
;
    }
    _update($self,
	    $server,
	    $server->head_uri($self, 'GRAPH'),
	    $server->head_uri($self, 'BASE'));
}

# This method is just for the user interface.
sub update_status {
    (@_ == 3) or confess "\tBUG";
    my ($self, $server, $all) = @_;
    my $version = $self->version;
    my $head_version = $server->head_version($self);
    my $head_state = $server->head_prop($self, 'STATE');
    unless ($head_state eq 'OK') {
	return "in state $head_state";
    }
    if ($version < $head_version) {
	return "loaded ($head_version) newer than source ($version)?!?";
    }
    my $whynot = $self->cannot_update($server, $version, $all);
    if ($whynot) {
	if ($version == $head_version) {
	    return "update blocked: $whynot";
	} else {
	    return "update ($head_version => $version) blocked: $whynot";
	}
    }
    if (!$all) {
	if ($version == $head_version) {
	    return "up to date ($version)";
	} else {
	    return "update ($head_version => $version) available";
	}
    } else {
	my %plan = ();
	my $rv = "";
	$self->update($server, $version, $all, \%plan);
	for my $bname (sort(keys(%plan))) {
	    my $bundle = $server->find_bundle($bname);
	    my $head_bversion = $server->head_version($bundle);
	    my $bversion = $bundle->version;
	    my $btarget = $plan{$bname};
	    $rv .= "\n\t$bname: update ($head_bversion => $bversion) available";
	}
	return $rv;
    }
}

sub cmd_load_specs {
    my ($self) = @_;
    for my $spec (@{$self->load_specs}) {
	for my $key (sort(keys(%$spec))) {
	    print "  $key:\n    ";
	    display($spec->{$key});
	    print "\n";
	}
	print "-----\n"
    }
    'OK'
}

sub command_table {
    my ($self) = @_;
    return hash_compose({
	load_specs => {
	    proc => \&cmd_load_specs,
	    doc => "Show the fully parsed load specifications.",
	},
    }, $self->SUPER::command_table);
}
1;
__END__

# Local Variables:
# mode: Perl
# End:
