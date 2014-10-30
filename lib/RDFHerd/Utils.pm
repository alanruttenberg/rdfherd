# Utilities for RDFHerd
#
# Copyright © 2008-2010  Creative Commons Corp.
#
# $Id: Utils.pm 3580 2010-08-18 22:51:54Z bawden $

package RDFHerd::Utils;

use 5.008_005;
use strict;
use integer;
use Carp;
use DB_File;
use English '-no_match_vars';
use Exporter;
use Fcntl qw(O_RDONLY O_RDWR O_CREAT LOCK_SH LOCK_EX LOCK_NB);
use FileHandle;
use POSIX qw(EWOULDBLOCK ENOENT
	     WIFEXITED WEXITSTATUS WIFSIGNALED
	     WTERMSIG WIFSTOPPED WSTOPSIG);
use Safe;
use Sys::Hostname qw(hostname);
use Term::ReadKey qw(ReadMode);
use Time::HiRes qw(gettimeofday);

sub make_constructor ($$$%);

our (@ISA, $VERSION, @EXPORT_OK);
@ISA = qw(Exporter);
$VERSION = 1.18_01;
@EXPORT_OK = qw(load_config check_version check_class_version
		unsupported_interface
		site_config get_config_string
		get_config_list get_config_ref get_config_path
		state_file_open state_file_close
		env_lookup
		mjdtime mjdtime_diff mjdtime_add mjdtime_cmp
		yes_or_no password_read
		full_hostname short_hostname
		hash_compose
		ordered_keys
		erase_file evacuate_directory directory_is_empty
		exit_check
		foreach_file
		make_constructor
		write_hash read_hash
		display);

my $site_config_path = "/etc/rdfherd-config.pl";

# Config bindings will look like:
#	my $bindings = {
#	    T => \+1,
#	    F => \+0,
#	    Cons => make_constructor([qw(CAR CDR)], [], [], TYPE => 'Cons'),
#	};

sub load_config ($;$) {
    my ($path, $bindings) = @_;
    my $cf = new Safe;

    # Minimal environment.
    # See "perldoc Opcode".
    # Opcode::opdump("foobar") might be useful...
    $cf->permit_only(qw(:base_core :base_mem :base_loop :base_orig));

    my $root = $cf->root;
    if ($bindings) {
	while (my ($name, $val) = each(%$bindings)) {
	    ref($val) or die "Bad binding for $name";
	    no strict;
	    *{"${root}::$name"} = $val;
	}
    }

    $ERRNO = 0;			# probably a meaningless gesture
    my $rv = $cf->rdo($path);
    die($EVAL_ERROR) if ($EVAL_ERROR);
    die("$ERRNO: $path\n") if (not defined($rv) and $ERRNO);
    die("$path must return a hash.\n") if (ref($rv) ne 'HASH');
    return $rv;
}

sub check_version ($$$$$) {
    my ($my_min, $my_max, $path, $its_min, $its_max) = @_;
    ($my_min <= $my_max)
	or confess "Bad version number range: [$my_min, $my_max]\n\tBUG";
    ($its_min <= $its_max)
	or die "Bad version numbers [$its_min, $its_max] in $path\n";
    ($my_min <= $its_max)
	or die "Version $its_max is no longer supported: $path\n";
    ($its_min <= $my_max)
	or die "Version $its_min is too new for me: $path.\nYou need up update to a newer version of the RDFHerd package.  (Sorry for\nthe inconvenience -- we try not to do this unless it is absolutely necessary.)\n";
    if ($my_max <= $its_max) {
	return $my_max;
    } else {
	return $its_max;
    }
}

sub check_class_version ($$$$) {
    my ($code_min, $code_max, $path, $cfg) = @_;
    my ($data_min, $data_max);
    # OK, so 0 isn't available as a version number...
    $data_max = ($cfg->{class_version} ||= 1);
    $data_min = ($cfg->{compatible_class_version} ||= $data_max);
    return check_version($code_min, $code_max, $path, $data_min, $data_max);
}

sub unsupported_interface ($$@) {
    my ($interface, $obj) = @_;
    my $path = $obj->path;
    my $class_name = $obj->class_name;
    die "$path (class $class_name) is not a $interface.\n";
}

my $site_config_cache = 0;

# site_config <name> [<default-value>]
sub site_config ($;$) {
    my ($param) = @_;
    unless ($site_config_cache) {
	$site_config_cache = load_config($site_config_path);
    }
    if (exists($site_config_cache->{$param})) {
	return $site_config_cache->{$param};
    } elsif (@_ > 1) {
	return $_[1];
    } else {
	die "$param not defined in $site_config_path\n";
    }
}

# get_config_string <cfg> <param>
sub get_config_string ($$) {
    my ($cfg, $param) = @_;
    my $value = $cfg->{$param};
    if (!$value || ref($value)) {
	die "Bad or missing value for $param.\n";
    }
    return $value;
}

# get_config_list <cfg> <param>
sub get_config_list ($$) {
    my ($cfg, $param) = @_;
    my $value = $cfg->{$param};
    if (!$value || ref($value) ne 'ARRAY') {
	die "Bad or missing value for $param.\n";
    }
    return $value;
}

# get_config_ref <cfg> <param> <key>
sub get_config_ref ($$$) {
    my ($cfg, $param, $key) = @_;
    my $value = $cfg->{$param};
    unless ($value and
	    (ref($value) eq 'HASH' or
	     ref($value) eq 'ARRAY')) {
	die "Bad or missing value for $param.\n";
    }
    if (ref($value) eq 'HASH' and
	defined($value->{$key})) {
	return $value->{$key};
    }
    if (ref($value eq 'ARRAY') and
	$key =~ m(^\d+\z) and
	defined($value->[$key])) {
	return $value->[$key];
    }
    die "Bad key ($key) for $param.\n";
}

# get_config_path <cfg> <param>
sub get_config_path ($$);		# Perl sucks
sub get_config_path ($$) {
    my ($cfg, $param) = @_;
    my $path = get_config_string($cfg, $param);
    my ($dir, $rest);
    if (($dir, $rest) = $path =~ m(^(.*?)(/.*)\z)) {
	return $rest unless $dir;
	$dir = get_config_path($cfg, $dir . "_dir");
	return $dir . $rest;
    } else {
	return get_config_path($cfg, $path . "_dir");
    }
}

#
# State provider utilities
#

sub state_file_open ($$$) {
    my ($obj, $mode, $if_blocked) = @_;
    my $file = $obj->{state_file} or
	confess "Missing state file name\n\tBUG";
    my $flags;
    my $flock = (($if_blocked eq 'WAIT') ? 0 : LOCK_NB);
    if ($mode eq 'READ') {
	$flags = O_RDONLY;
	$flock |= LOCK_SH;
    } else {
	$flags = O_CREAT | O_RDWR;
	$flock |= LOCK_EX;
    }
    my %state;
    my $lock = new FileHandle;
    if ($lock->open("$file.lock", $flags, 0666)) {
	unless (flock($lock, $flock)) {
	    if ($ERRNO == EWOULDBLOCK) {
		return 0 if ($if_blocked eq 'RETURN');
		my $path = $obj->path;
		die "Locked by somebody else: $path\n";
	    }
	    croak "$ERRNO: $file.lock";
	}
	$obj->{state_lock} = $lock;
	unless (tie(%state, "DB_File", "$file.db", $flags, 0666)) {
	    croak "$ERRNO: $file.db";
	}
    } elsif ($mode ne 'READ' or
	    $ERRNO != ENOENT or
	    -e "$file.db") {
	croak "$ERRNO: $file.lock";
    }
    $obj->{state} = \%state;
    $obj->{state_mode} = $mode;
    return \%state;
}

sub state_file_close ($) {
    my ($obj) = @_;
    my $state = $obj->{state};
    if ($state) {
	delete($obj->{state});
	untie(%$state);
	$obj->{state_mode} = 'CLOSE';
    }
    my $lock = $obj->{state_lock};
    if ($lock) {
	$lock->close();
	$obj->{state_lock} = 0;
    }
}

#
# Classic environments: frame with NEXT, or procedural
#

sub env_lookup ($$$); 		# Perl sucks
sub env_lookup ($$$) {
    my ($env, $key, $default) = @_;
    if (ref($env) eq 'CODE') {
	return &$env($key, $default);
    }
    if (exists($env->{$key})) {
	return $env->{$key};
    }
    my $next = $env->{NEXT};
    if ($next) {
	return env_lookup($next, $key, $default);
    } else {
	return $default;
    }
}

#
# Time
#

use constant {
    SPD => 24 * 60 * 60,		# seconds per day
    MSPD => 24 * 60 * 60 * 1000,	# milliseconds per day
    MJD_1JAN1970 => 40587,
};

sub mjdtime (;$) {
    my ($secs, $micro);
    if (@_) {
	$secs = $_[0];
	$micro = 0;
    } else {
	($secs, $micro) = gettimeofday();
    }
    return (MJD_1JAN1970 + $secs / SPD,		   # days
	    ($secs % SPD) * 1000 + $micro / 1000,  # milliseconds (10^-3)
	    ($micro % 1000) * 1_000_000);	   # picoseconds  (10^-12)
}

# Despite the picoseconds returned by mjdtime(), the rest of these
# utilities just work with milliseconds.

sub mjdtime_diff ($$) {
    my ($t1, $t2) = @_;
    my $days = $t1->[0] - $t2->[0];
    my $msecs = $t1->[1] - $t2->[1];
    while ($msecs < 0) {
	$msecs += MSPD;
	$days -= 1;
    }
    return ($days, $msecs);
}

sub mjdtime_add ($$) {
    my ($t1, $t2) = @_;
    my $days = $t1->[0] + $t2->[0];
    my $msecs = $t1->[1] + $t2->[1];
    $days += $msecs / MSPD;
    $msecs %= MSPD;
    return ($days, $msecs);
}

sub mjdtime_cmp ($$) {
    my ($t1, $t2) = @_;
    return ($t1->[0] - $t2->[0]) || ($t1->[1] - $t2->[1]);
}

sub yes_or_no ($) {
    my ($question) = @_;
    for (;;) {
	print $question, " (yes or no) ";
	my $line = <STDIN>;
	chomp($line);
	$line = lc($line);
	return 1 if ($line eq 'yes');
	return 0 if ($line eq 'no');
	print "Please type \"yes\" for yes or \"no\" for no.\n";
    }
}

sub password_read ($) {
    my ($prompt) = @_;
    print $prompt, ": ";
    ReadMode 2;
    my $line = <STDIN>;
    ReadMode 0;
    print "\n";
    chomp($line);
    return $line;
}

my $full_hostname_cache = 0;

sub full_hostname () {
    unless ($full_hostname_cache) {
        $full_hostname_cache
            = lc((gethostbyname(hostname()))[0] ||
                 croak "Error $CHILD_ERROR: gethostbyname().");
    }
    return $full_hostname_cache;
}

my $short_hostname_cache = 0;

sub short_hostname () {
    unless ($short_hostname_cache) {
        $short_hostname_cache = lc(hostname());
	$short_hostname_cache =~ s(\..*\z)();
    }
    return $short_hostname_cache;
}

# Basic directory listing...
sub list_dir ($) {
    my $d = shift;
    opendir(DIR, $d) or croak "$ERRNO: $d\n";
    my @names = readdir(DIR);
    closedir(DIR) or die;
    return @names;
}

# Make sure some file doesn't exist.
sub erase_file ($) {
    my ($file) = @_;
    unlink($file) or
	($ERRNO == ENOENT) or
	die "$ERRNO: deleting $file\n";
}

# Make sure some directory is empty.
sub evacuate_directory ($) {
    my ($dir) = @_;
    for my $entry (list_dir($dir)) {
	next if ($entry =~ m(^\.));
	unlink("$dir/$entry") or
	    die "$ERRNO: deleting $dir/$entry\n";
    }
}

# Check that some directory is empty.
sub directory_is_empty ($) {
    my ($dir) = @_;
    for my $entry (list_dir($dir)) {
	return 0 unless ($entry =~ m(^\.));
    }
    return 1;
}

sub hash_compose {
    my $rv = {};
    while (my $h = pop(@_)) {
	for my $k (keys(%{$h})) {
	    $rv->{$k} = $h->{$k};
	}
    }
    return $rv;
}

# The real utility of this is that you can pass it an even length array
# reference, and it will behave like a hash reference that remembers what
# order it was written in.
sub ordered_keys ($) {
    my ($x) = @_;
    if (ref($x) eq 'HASH') {
	my @keys = sort(keys(%$x));
	return (\@keys, $x);
    } elsif (ref($x) eq 'ARRAY') {
	my @keys = ();
	my $len = @$x;
	($len % 2 == 0) or croak "Not an even length array: $x";
	my $i = 0;
	while ($i < $len) {
	    push(@keys, $x->[$i]);
	    $i += 2;
	}
	return (\@keys, {@$x});
    } else {
	croak "Not a hash or array reference: $x";
    }
}

# The usual way to check CHILD_ERROR is to insist on a normal return with
# an exit status less than some limit.  The limit is often 1.
sub exit_check ($;$$) {
    my $what = shift;
    my $limit = shift || 1;
    my $v = shift || $CHILD_ERROR;
    if (WIFEXITED($v)) {
        my $status = WEXITSTATUS($v);
        if ($status < $limit) {
            return $status;
        } else {
            croak "$what exited with status $status";
        }
    } elsif (WIFSIGNALED($v)) {
        my $sig = WTERMSIG($v);
        croak "$what terminated with signal $sig";
    } elsif (WIFSTOPPED($v)) {
        my $sig = WSTOPSIG($v);
        croak "$what stopped with signal $sig";
    } else {
        croak "$what: weird exit status: $v";
    }
}

#
# Better than File::Find::find (for our purposes)
#

# XXX does this do the "right" thing if it encounters a symlink?
sub foreach_file_1 ($$$);	# Perl sucks
sub foreach_file_1 ($$$) {
    my ($dir, $xdir, $proc) = @_;
    my ($name, $entry, $xentry, $rv);
    my @names = list_dir($dir);
    for $name (sort(@names)) {
	next if ($name =~ m(^\.) || $name =~ m(~\z));
	$entry = $dir . $name;
	$xentry = $xdir . $name;
	if (-d $entry) {
	    $rv = foreach_file_1($entry . "/", $xentry . "/", $proc);
	    if ($rv) { return $rv }
	} elsif (-f $entry) {
	    $rv = &$proc($entry, $xentry);
	    if ($rv) { return $rv }
	}
    }
    return 0;
}

sub foreach_file ($$$) {
    my ($dir, $xdir, $proc) = @_;
    $dir =~ s(/*\z)(/);
    unless ($xdir eq "") {
	$xdir =~ s(/*\z)(/);
    }
    foreach_file_1($dir, $xdir, $proc);
}

#
# Convenient constructors for hashes.
#
sub make_constructor ($$$%) {
    my ($positional, $required, $optional, %defaults) = @_;
    my %allkeys;
    my %legal_key;
    for my $k (@$positional, @$required) {
	if (exists($defaults{$k})) {
	    croak "Why does '$k' have a default value?";
	}
    }
    for my $k (@$positional, @$required, @$optional) {
	if ($allkeys{$k}) {
	    croak "Duplicated key: '$k'";
	}
	$allkeys{$k} = 1;
    }
    for my $k (@$required, @$optional) {
	$legal_key{$k} = 1;
    }
    my $npositional = @$positional;
    return sub {
	my $i = @_;
	my $key;
	unless (($i >= $npositional) and (($i - $npositional) % 2 == 0)) {
	    croak "Wrong number of arguments to constructor";
	}
	my %rv = %defaults;
	@rv{@$positional} = @_;
	while ($i > $npositional) {
	    $i -= 2;
	    $key = $_[$i];
	    unless ($legal_key{$key}) {
		croak "Illegal key to constructor: $key";
	    }
	    $rv{$key} = $_[$i + 1];
	}
	for $key (@$required) {
	    unless (exists($rv{$key})) {
		croak "Missing key to constructor: $key";
	    }
	}
	return \%rv;
    }
}

#
# A simple format for saving simple key-value structures in files.
#

# A hash is written out as a series of lines terminated by a line
# consisting of a single ".".  Each key-value pair is written as a line in
# the form "<key>:<value>".  If <value> contains newlines, continuation
# lines are written in the form "-<more>".  Keys can only contain Perl
# "word" characters.  Values can be any scalar value.

# write_hash(<filehandle>, <hashref>)
sub write_hash ($$) {
    my ($fh, $hashref) = @_;
    while (my ($key, $value) = each(%$hashref)) {
	if ($key !~ m(^\w+\z)) {
	    croak "Non-word key in hash: $key";
	}
	if (ref($value)) {
	    croak "Non-scalar value in hash: $value";
	}
	$value =~ s(\n)(\n-)g;
	print $fh "$key:$value\n";
    }
    print $fh ".\n";
}

# read_hash(<filehandle>) => <hashref>
# Returns 0 at EOF.
sub read_hash ($) {
    my ($fh) = @_;
    my %hash = ();
    my $key;
    my $value;
    while (<$fh>) {
	chomp;
	if (m(^-(.*)\z)) {
	    unless (defined($key)) {
		die "Misplaced continuation line: $_\n";
	    }
	    $value .= "\n" . $1;
	    next;
	} 
	if (defined($key)) {
	    $hash{$key} = $value;
	}
	if (m(^(\w+):(.*)\z)) {
	    $key = $1;
	    $value = $2;
	    next;
	}
	if (m(^\.\z)) {
	    return \%hash;
	}
	die "Bogus line: $_\n";
    }
    if (defined($key)) {
	$hash{$key} = $value;
    }
    if (%hash) {
	my @keys = keys(%hash);
	die "Unexpected EOF.  Last keys: @keys\n";
    }
    return 0;
}

my %display_proc = (
    HASH		=> \&display_ref_hash,
    ARRAY		=> \&display_ref_array,
    SCALAR		=> \&display_ref_scalar,
    REF			=> \&display_ref_ref,
    "RDFHerd::Term"	=> \&display_term,
    );

my $display_level = 4;

sub display ($;$) {
    my $x = shift;
    my $level = shift || $display_level;
    my $ref = ref($x);
    if (not $ref) {
	display_plain($x);
    } else {
	my $proc = $display_proc{$ref};
	if (not $proc or $level <= 0) {
	    print $x;
	} else {
	    &{$proc}($x, $level - 1);
	}
    }
}

sub display_plain ($) {
    my ($x) = @_;
    if (not defined($x)) {
	print "UNDEF()"
    } elsif ($x =~ m(^\w+\z)) {
	print $x;
    } else {
	print "\"$x\"";
    }
}

sub comma_list ($$) {
    my ($x, $n) = @_;
    my $first = 1;
    for my $v (@{$x}) {
	if ($first) {
	    $first = 0;
	} else {
	    print ", ";
	}
	display($v, $n);
    }
}

sub hash_list ($$@) {
    my ($x, $n, @keys) = @_;
    my $first = 1;
    for my $k (@keys) {
	if ($first) {
	    $first = 0;
	} else {
	    print ", ";
	}
	display_plain($k);
	print " => ";
	display($x->{$k}, $n);
    }
}

sub display_ref_hash ($$) {
    my ($x, $n) = @_;
    print "{";
    hash_list($x, $n, sort(keys(%{$x})));
    print "}";
}

sub display_ref_array ($$) {
    my ($x, $n) = @_;
    print "[";
    comma_list($x, $n);
    print "]";
}

sub display_ref_scalar ($$) {
    my ($x, $n) = @_;
    print "\\+";
    display_plain($$x);
}

sub display_ref_ref ($$) {
    my ($x, $n) = @_;
    print "\\";
    display($$x, $n);
}

sub display_term ($$) {
    my ($x, $n) = @_;
    display_plain($x->operator);
    print "(";
    hash_list($x, $n, keys(%{$x->keys}));
    print ")";
}

1;
__END__

# Local Variables:
# mode: Perl
# End:
